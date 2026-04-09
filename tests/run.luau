local Regexp = require("../src/Regexp")
local Grep = require("../src/Grep")
local CharClass = require("../src/regexp/CharClass")
local Fixtures = require("./support/CppFixtures")
local fs = require("@lune/fs")

local failures = {}

local function fail(message: string)
	table.insert(failures, message)
end

local function preview(text: string, limit: number?): string
	limit = limit or 120
	if #text <= limit then
		return text
	end
	return string.sub(text, 1, limit - 3) .. "..."
end

local function expectEqual(actual, expected, label)
	if actual ~= expected then
		fail(string.format("%s\nexpected: %s\nactual:   %s", label, tostring(expected), tostring(actual)))
	end
end

local function expectTruthy(value, label)
	if not value then
		fail(label)
	end
end

local function expectParseFailure(regexpText, flags, expectedCode, expectedArg, label)
	local status = Regexp.newStatus()
	local re = Regexp.Parse(regexpText, flags, status)
	expectEqual(re, nil, label .. " should fail")
	if re == nil then
		expectTruthy(not status:ok(), label .. " should set failure status")
		if expectedCode ~= nil then
			expectEqual(status:code(), expectedCode, label .. " error code")
		end
		if expectedArg ~= nil then
			expectEqual(status:error_arg(), expectedArg, label .. " error arg")
		end
	end
end

local function parseOrFail(regexpText, flags, label)
	local status = Regexp.newStatus()
	local re = Regexp.Parse(regexpText, flags, status)
	if re == nil then
		fail(string.format("%s parse failed: %s (%s)", label, status:Text(), status:error_arg()))
	end
	return re, status
end

local function runParseTests()
	local fixtures = Fixtures.loadParseFixtures(Regexp)
	local kTestFlags = bit32.bor(Regexp.MatchNL, Regexp.PerlX, Regexp.PerlClasses, Regexp.UnicodeGroups)
	local groups = {
		{ name = "tests", cases = fixtures.tests, flags = kTestFlags },
		{ name = "foldcase", cases = fixtures.foldcase_tests, flags = Regexp.FoldCase },
		{ name = "literal", cases = fixtures.literal_tests, flags = Regexp.Literal },
		{ name = "matchnl", cases = fixtures.matchnl_tests, flags = Regexp.MatchNL },
		{ name = "nomatchnl", cases = fixtures.nomatchnl_tests, flags = Regexp.NoParseFlags },
		{ name = "prefix", cases = fixtures.prefix_tests, flags = Regexp.PerlX },
		{ name = "nested", cases = fixtures.nested_tests, flags = Regexp.PerlX },
	}

	for _, group in ipairs(groups) do
		local parsed = {}
		for _, case in ipairs(group.cases) do
			local flags = group.flags
			if case.flags ~= 0 then
				flags = bit32.band(case.flags, bit32.bnot(Regexp.WasDollar))
			end
			local re = parseOrFail(case.regexp, flags, group.name .. " " .. case.regexp)
			if re ~= nil then
				expectEqual(re:Dump(), case.parse, group.name .. " dump for " .. case.regexp)
				local roundTrip = re:ToString()
				local reparsed = parseOrFail(roundTrip, flags, group.name .. " reparse " .. case.regexp)
				if reparsed ~= nil then
					expectEqual(reparsed:Dump(), re:Dump(), group.name .. " roundtrip dump for " .. case.regexp)
					expectEqual(reparsed:ToString(), roundTrip, group.name .. " roundtrip tostring for " .. case.regexp)
				end
				table.insert(parsed, { regexp = case.regexp, dump = case.parse, re = re })
			end
		end

		for i = 1, #parsed do
			for j = 1, #parsed do
				local want = parsed[i].dump == parsed[j].dump
				local have = Regexp.Equal(parsed[i].re, parsed[j].re)
				if want ~= have then
					fail(string.format("equality mismatch %s vs %s", parsed[i].regexp, parsed[j].regexp))
				end
			end
		end
	end

	for _, text in ipairs(fixtures.badtests) do
		local status = Regexp.newStatus()
		if Regexp.Parse(text, Regexp.PerlX, status) ~= nil then
			fail("expected invalid perl regexp: " .. text)
		end
		status = Regexp.newStatus()
		if Regexp.Parse(text, Regexp.NoParseFlags, status) ~= nil then
			fail("expected invalid posix regexp: " .. text)
		end
	end

	for _, text in ipairs(fixtures.only_posix) do
		local status = Regexp.newStatus()
		if Regexp.Parse(text, Regexp.PerlX, status) ~= nil then
			fail("expected perl-only failure for: " .. text)
		end
		if Regexp.Parse(text, Regexp.NoParseFlags, Regexp.newStatus()) == nil then
			fail("expected posix parse success for: " .. text)
		end
	end

	for _, text in ipairs(fixtures.only_perl) do
		local status = Regexp.newStatus()
		if Regexp.Parse(text, Regexp.NoParseFlags, status) ~= nil then
			fail("expected posix failure for perl construct: " .. text)
		end
		if Regexp.Parse(text, Regexp.PerlX, Regexp.newStatus()) == nil then
			fail("expected perl parse success for: " .. text)
		end
	end

	do
		local status = Regexp.newStatus()
		local re = Regexp.Parse("test(?P<name", Regexp.LikePerl, status)
		expectEqual(re, nil, "named capture missing close should fail")
		expectEqual(status:code(), Regexp.kRegexpBadNamedCapture, "named capture error code")
		expectEqual(status:error_arg(), "(?P<name", "named capture error arg")
	end

	do
		local status = Regexp.newStatus()
		local re = Regexp.Parse("test(?P<space bar>z)", Regexp.LikePerl, status)
		expectEqual(re, nil, "named capture space should fail")
		expectEqual(status:code(), Regexp.kRegexpBadNamedCapture, "named capture space error code")
		expectEqual(status:error_arg(), "(?P<space bar>", "named capture space error arg")
	end

	do
		local status = Regexp.newStatus()
		local re = Regexp.Parse("test(?<name", Regexp.LikePerl, status)
		expectEqual(re, nil, "angle named capture missing close should fail")
		expectEqual(status:code(), Regexp.kRegexpBadNamedCapture, "angle named capture error code")
		expectEqual(status:error_arg(), "(?<name", "angle named capture error arg")
	end

	do
		local status = Regexp.newStatus()
		local re = Regexp.Parse("test(?<space bar>z)", Regexp.LikePerl, status)
		expectEqual(re, nil, "angle named capture space should fail")
		expectEqual(status:code(), Regexp.kRegexpBadNamedCapture, "angle named capture space code")
		expectEqual(status:error_arg(), "(?<space bar>", "angle named capture space arg")
	end

	for _, look in ipairs({
		{ "(?=foo).*", "(?=" },
		{ "(?!foo).*", "(?!" },
		{ "(?<=foo).*", "(?<=" },
		{ "(?<!foo).*", "(?<!" },
	}) do
		local status = Regexp.newStatus()
		local re = Regexp.Parse(look[1], Regexp.LikePerl, status)
		expectEqual(re, nil, "look-around should fail: " .. look[1])
		expectEqual(status:code(), Regexp.kRegexpBadPerlOp, "look-around error code for " .. look[1])
		expectEqual(status:error_arg(), look[2], "look-around error arg for " .. look[1])
	end
end

local function runPCRE2Tests()
	local flags = Regexp.LikePCRE2
	local cases = {
		{ regexp = "(?=foo)bar", dump = "cat{pla{str{foo}}str{bar}}" },
		{ regexp = "(?!foo)bar", dump = "cat{nla{str{foo}}str{bar}}" },
		{ regexp = "(?<=foo)bar", dump = "cat{plb{str{foo}}str{bar}}" },
		{ regexp = "(?<!foo)bar", dump = "cat{nlb{str{foo}}str{bar}}" },
		{ regexp = "(?>ab|ac)d", dump = "cat{atomic{cat{lit{a}cc{0x62-0x63}}}lit{d}}" },
		{ regexp = "a*+", dump = "pstar{lit{a}}" },
		{ regexp = "a++", dump = "pplus{lit{a}}" },
		{ regexp = "a?+", dump = "pque{lit{a}}" },
		{ regexp = "a{2,4}+", dump = "prep{2,4 lit{a}}" },
		{ regexp = "([a-z]+)\\1", dump = "cat{cap{plus{cc{0x61-0x7a}}}backref{1}}" },
		{ regexp = "(?<word>[a-z]+)\\k<word>", dump = "cat{cap{word:plus{cc{0x61-0x7a}}}backref{word}}" },
		{ regexp = "(?P<word>[a-z]+)(?P=word)", dump = "cat{cap{word:plus{cc{0x61-0x7a}}}backref{word}}" },
	}

	for _, case in ipairs(cases) do
		local re = parseOrFail(case.regexp, flags, "pcre2 " .. case.regexp)
		if re ~= nil then
			expectEqual(re:Dump(), case.dump, "pcre2 dump for " .. case.regexp)
			local roundTrip = re:ToString()
			local reparsed = parseOrFail(roundTrip, flags, "pcre2 reparse " .. case.regexp)
			if reparsed ~= nil then
				expectEqual(reparsed:Dump(), re:Dump(), "pcre2 roundtrip dump for " .. case.regexp)
				expectEqual(reparsed:ToString(), roundTrip, "pcre2 roundtrip tostring for " .. case.regexp)
				expectTruthy(Regexp.Equal(re, reparsed), "pcre2 equality for " .. case.regexp)
			end

			local simplified = re:Simplify()
			expectTruthy(simplified ~= nil, "pcre2 simplify returned nil for " .. case.regexp)
		end
	end

	for _, case in ipairs({
		{ regexp = "(?=foo)bar", arg = "(?=" },
		{ regexp = "(?<=foo)bar", arg = "(?<=" },
		{ regexp = "a*+", arg = "+" },
	}) do
		local status = Regexp.newStatus()
		local re = Regexp.Parse(case.regexp, Regexp.LikePerl, status)
		expectEqual(re, nil, "expected LikePerl to reject PCRE2-only syntax: " .. case.regexp)
		if case.arg ~= "+" then
			expectEqual(status:code(), Regexp.kRegexpBadPerlOp, "LikePerl error code for " .. case.regexp)
			expectEqual(status:error_arg(), case.arg, "LikePerl error arg for " .. case.regexp)
		else
			expectEqual(status:code(), Regexp.kRegexpInvalidRepeat, "LikePerl possessive repeat code")
		end
	end

	do
		local re = parseOrFail("\\e\\cA", flags, "pcre2 escape support")
		if re ~= nil then
			local roundTrip = re:ToString()
			local reparsed = parseOrFail(roundTrip, flags, "pcre2 escape support reparse")
			if reparsed ~= nil then
				expectEqual(reparsed:Dump(), re:Dump(), "pcre2 escape support roundtrip dump")
			end
		end
	end

	for _, case in ipairs({
		{ regexp = "\\K", code = Regexp.kRegexpInvalidEscape, arg = "\\K" },
		{ regexp = "\\g{1}", code = Regexp.kRegexpInvalidEscape, arg = "\\g" },
		{ regexp = "\\G", code = Regexp.kRegexpInvalidEscape, arg = "\\G" },
		{ regexp = "\\Z", code = Regexp.kRegexpInvalidEscape, arg = "\\Z" },
		{ regexp = "\\v", code = Regexp.kRegexpInvalidEscape, arg = "\\v" },
		{ regexp = "(?|abc|def)", code = Regexp.kRegexpBadPerlOp, arg = "(?" },
		{ regexp = "(?R)", code = Regexp.kRegexpBadPerlOp, arg = "(?" },
		{ regexp = "(?(?=a)b|c)", code = Regexp.kRegexpBadPerlOp, arg = "(?" },
		{ regexp = "(*ACCEPT)", code = Regexp.kRegexpBadPerlOp, arg = "(*" },
		{ regexp = "(*UTF)abc", code = Regexp.kRegexpBadPerlOp, arg = "(*" },
	}) do
		expectParseFailure(case.regexp, flags, case.code, case.arg, "pcre2 unsupported " .. case.regexp)
	end
end

local function runPCRE2CorpusSmokeTests()
	local fixtures = Fixtures.loadPCRE2Patterns()
	expectTruthy(#fixtures.cases > 0, "expected PCRE2 corpus patterns to be discovered")

	for _, case in ipairs(fixtures.cases) do
		local label = string.format("%s:%d %s", case.file, case.line, preview(case.regexp))
		local status = Regexp.newStatus()
		local ok, re = pcall(Regexp.Parse, case.regexp, Regexp.LikePCRE2, status)
		if not ok then
			fail("pcre2 corpus parse crashed for " .. label .. "\nerror: " .. tostring(re))
			continue
		end

		if re == nil then
			if status:ok() or status:code() == nil then
				fail("pcre2 corpus parse failed without error status for " .. label)
			end
			continue
		end

		if #case.regexp > 512 then
			continue
		end

		local okDump, dump = pcall(function()
			return re:Dump()
		end)
		if not okDump then
			fail("pcre2 corpus dump crashed for " .. label .. "\nerror: " .. tostring(dump))
			continue
		end

		local okText, roundTrip = pcall(function()
			return re:ToString()
		end)
		if not okText then
			fail("pcre2 corpus tostring crashed for " .. label .. "\nerror: " .. tostring(roundTrip))
			continue
		end

		local roundTripStatus = Regexp.newStatus()
		local okReparse, reparsed = pcall(Regexp.Parse, roundTrip, Regexp.LikePCRE2, roundTripStatus)
		if not okReparse then
			fail("pcre2 corpus roundtrip parse crashed for " .. label .. "\nerror: " .. tostring(reparsed))
			continue
		end
		if reparsed == nil then
			fail(string.format(
				"pcre2 corpus roundtrip parse failed for %s\nrendered: %s\nstatus: %s (%s)",
				label,
				preview(roundTrip, 160),
				tostring(roundTripStatus:code()),
				roundTripStatus:error_arg()
			))
			continue
		end

		expectEqual(reparsed:Dump(), dump, "pcre2 corpus roundtrip dump for " .. label)

		local okSimplify, simplified = pcall(function()
			return re:Simplify()
		end)
		if not okSimplify then
			fail("pcre2 corpus simplify crashed for " .. label .. "\nerror: " .. tostring(simplified))
			continue
		end
		expectTruthy(simplified ~= nil, "pcre2 corpus simplify returned nil for " .. label)
	end
end

local function runMatchEngineTests()
	do
		local re = parseOrFail("world", Regexp.NoParseFlags, "match literal")
		if re ~= nil then
			local match, err = re:Search("hello world")
			expectEqual(err, nil, "literal search should not error")
			expectTruthy(match ~= nil, "literal search should match")
			if match ~= nil then
				expectEqual(match.text, "world", "literal search text")
				expectEqual(match.start, 7, "literal search start")
				expectEqual(match.finish, 12, "literal search finish")
			end

			local all, allErr = re:FindAll("world and world", 10)
			expectEqual(allErr, nil, "literal findall should not error")
			expectEqual(#(all or {}), 2, "literal findall count")

			local isMatch, isMatchErr = re:IsMatch("hello world")
			expectEqual(isMatchErr, nil, "literal ismatch should not error")
			expectEqual(isMatch, true, "literal ismatch should succeed")

			local full, fullErr = re:FullMatch("world")
			expectEqual(fullErr, nil, "literal fullmatch should not error")
			expectEqual(full, true, "literal fullmatch should succeed")

			local notFull = select(1, re:FullMatch("hello world"))
			expectEqual(notFull, false, "literal fullmatch should fail on partial")
		end
	end

	do
		local re = parseOrFail("(?m)^bar$", Regexp.LikePerl, "match multiline anchors")
		if re ~= nil then
			local match = select(1, re:Search("foo\nbar\nbaz"))
			expectTruthy(match ~= nil, "multiline anchor should match")
			if match ~= nil then
				expectEqual(match.text, "bar", "multiline anchor text")
			end

			local all = select(1, parseOrFail("(?m)^", Regexp.LikePerl, "match zero width multiline")):FindAll("a\nb", 10)
			expectEqual(#(all or {}), 2, "zero width multiline anchors should advance")
		end
	end

	do
		local re = parseOrFail("\\bcat\\b", Regexp.LikePerl, "match word boundary")
		if re ~= nil then
			local match = select(1, re:Search("a cat scatter"))
			expectTruthy(match ~= nil, "word boundary should match")
			if match ~= nil then
				expectEqual(match.text, "cat", "word boundary text")
				expectEqual(match.start, 3, "word boundary start")
			end
		end
	end

	do
		local re = parseOrFail("([a-z]+)\\1", Regexp.LikePCRE2, "match backref")
		if re ~= nil then
			local match = select(1, re:Search("abcabc xyz"))
			expectTruthy(match ~= nil, "backref should match")
			if match ~= nil then
				expectEqual(match.text, "abcabc", "backref text")
				expectTruthy(match.captures[1] ~= nil, "backref capture should exist")
				if match.captures[1] ~= nil then
					expectEqual(match.captures[1].text, "abc", "backref capture text")
				end
			end
		end
	end

	do
		local re = parseOrFail("foo(?=bar)", Regexp.LikePCRE2, "match lookahead")
		if re ~= nil then
			local match = select(1, re:Search("foobar fooqux"))
			expectTruthy(match ~= nil, "lookahead should match")
			if match ~= nil then
				expectEqual(match.text, "foo", "lookahead text")
			end
		end
	end

	do
		local re = parseOrFail("(?<=foo)bar", Regexp.LikePCRE2, "match lookbehind")
		if re ~= nil then
			local match = select(1, re:Search("xxfoobar"))
			expectTruthy(match ~= nil, "lookbehind should match")
			if match ~= nil then
				expectEqual(match.text, "bar", "lookbehind text")
			end
		end
	end

	do
		local atomic = parseOrFail("(?>a|ab)c", Regexp.LikePCRE2, "match atomic")
		if atomic ~= nil then
			local match = select(1, atomic:Search("abc"))
			expectEqual(match, nil, "atomic should prevent backtracking")
		end

		local possessive = parseOrFail("a*+a", Regexp.LikePCRE2, "match possessive")
		if possessive ~= nil then
			local match = select(1, possessive:Search("aa"))
			expectEqual(match, nil, "possessive repeat should prevent backtracking")
		end

		local plain = parseOrFail("a*a", Regexp.LikePerl, "match non possessive")
		if plain ~= nil then
			local match = select(1, plain:Search("aa"))
			expectTruthy(match ~= nil, "non possessive repeat should backtrack")
		end
	end

	do
		local re = parseOrFail("[A-Za-z_][A-Za-z0-9_]*", Regexp.LikePerl, "match simple repeat fast path")
		if re ~= nil then
			local subject = string.rep("identifier_", 600)
			local match, err = re:Search(subject)
			expectEqual(err, nil, "simple repeat fast path should not error")
			expectTruthy(match ~= nil, "simple repeat fast path should match")
			if match ~= nil then
				expectEqual(match.text, subject, "simple repeat fast path should consume full subject")
			end
		end
	end
end

local function runGrepModuleTests()
	local root = "/tmp/luau-regexp-grep"
	pcall(fs.removeDir, root)
	fs.writeDir(root)
	fs.writeDir(root .. "/nested")
	fs.writeFile(root .. "/main.luau", "local value = 1\n-- TODO: wire search\nreturn value\n")
	fs.writeFile(root .. "/nested/notes.txt", "TODO later\nno issue\n")
	fs.writeFile(root .. "/nested/image.png", "\137PNG\r\n")

	local result, err = Grep.searchPath(root, "TODO", {
		flags = Regexp.NoParseFlags,
		maxMatches = 10,
		maxMatchesPerFile = 10,
		extensions = { ".luau", ".txt" },
	})
	expectEqual(err, nil, "grep path should not error")
	expectTruthy(result ~= nil, "grep path should return results")
	if result ~= nil then
		expectEqual(result.totalMatches, 2, "grep path total matches")
		expectEqual(result.fileCount, 2, "grep path file count")
		expectTruthy(result.results[1] ~= nil, "grep path first file result")
		if result.results[1] ~= nil and result.results[1].matches[1] ~= nil then
			expectTruthy(result.results[1].matches[1].line ~= nil, "grep match line should exist")
			expectTruthy(result.results[1].matches[1].column ~= nil, "grep match column should exist")
			expectTruthy(result.results[1].matches[1].lineText ~= nil, "grep match line text should exist")
		end
	end

	do
		local matches, err = Grep.searchText("(?m)^TODO$", "skip\nTODO\nTODO\n", {
			flags = Regexp.LikePerl,
			maxMatches = 10,
		})
		expectEqual(err, nil, "grep text multiline should not error")
		expectEqual(#(matches or {}), 2, "grep text multiline count")
		if matches ~= nil and matches[1] ~= nil then
			expectEqual(matches[1].line, 2, "grep text multiline first line")
			expectEqual(matches[1].column, 1, "grep text multiline first column")
			expectEqual(matches[1].start, 6, "grep text multiline absolute start")
		end
	end

	do
		local lines = {}
		for index = 1, 2000 do
			lines[index] = "local value = " .. tostring(index)
		end
		lines[1500] = "return error_handler(value)"
		local matches, err = Grep.searchText("(?=.{0,120}error).+", table.concat(lines, "\n"), {
			flags = Regexp.LikePCRE2,
			maxMatches = 5,
		})
		expectEqual(err, nil, "grep line-mode query should not error on large multiline text")
		expectEqual(#(matches or {}), 1, "grep line-mode query should find one matching line")
		if matches ~= nil and matches[1] ~= nil then
			expectEqual(matches[1].line, 1500, "grep line-mode query line number")
			expectEqual(matches[1].lineText, "return error_handler(value)", "grep line-mode query line text")
		end
	end

	pcall(fs.removeDir, root)
end

local function containsRanges(ranges, value)
	for _, range in ipairs(ranges) do
		if range.lo <= value and value <= range.hi then
			return true
		end
	end
	return false
end

local function runCharClassTests()
	local fixtures = Fixtures.loadCharClassFixtures()
	for index, case in ipairs(fixtures.tests) do
		local cc = CharClass.new()
		for _, range in ipairs(case.add) do
			cc:addRange(range.lo, range.hi)
		end
		if case.remove >= 0 then
			cc:removeAbove(case.remove)
		end

		local function checkClass(classValue, label)
			expectEqual(#classValue.ranges, #case.final, label .. " range count " .. tostring(index))
			for i, range in ipairs(case.final) do
				local got = classValue.ranges[i]
				if got == nil or got.lo ~= range.lo or got.hi ~= range.hi then
					fail(string.format("%s range mismatch on case %d at %d", label, index, i))
				end
			end
			local size = 0
			for _, range in ipairs(case.final) do
				size += range.hi - range.lo + 1
			end
			expectEqual(classValue:size(), size, label .. " size case " .. tostring(index))
			for value = 0, 100 do
				local probe = value
				if probe == 100 then
					probe = 0x10FFFF
				end
				local want = containsRanges(case.final, probe)
				local have = classValue:contains(probe)
				if want ~= have then
					fail(string.format("%s contains mismatch case %d for %d", label, index, probe))
				end
			end

			local neg = classValue:negate()
			expectEqual(neg:size(), 0x10FFFF + 1 - classValue:size(), label .. " negated size " .. tostring(index))
			for value = 0, 100 do
				local probe = value
				if probe == 100 then
					probe = 0x10FFFF
				end
				local want = not containsRanges(case.final, probe)
				local have = neg:contains(probe)
				if want ~= have then
					fail(string.format("%s negated contains mismatch case %d for %d", label, index, probe))
				end
			end
		end

		checkClass(cc, "builder")
		checkClass(cc:copy(), "copy")
	end
end

local function runRegexpTests()
	local status = Regexp.newStatus()
	local re = Regexp.Parse("x", Regexp.NoParseFlags, status)
	expectTruthy(re ~= nil, "x should parse")
	if re ~= nil then
		for _ = 1, 100000 do
			re:Incref()
		end
		for _ = 1, 100000 do
			re:Decref()
		end
		expectEqual(re:Ref(), 1, "ref count after big incref/decref")
		re:Decref()
	end

	status = Regexp.newStatus()
	local x = Regexp.Parse("x", Regexp.NoParseFlags, status)
	expectTruthy(x ~= nil, "x literal should parse")
	if x ~= nil then
		local values = {}
		for _ = 1, 90000 do
			x:Incref()
			table.insert(values, x)
		end
		local re2 = Regexp.Concat(values, #values, Regexp.NoParseFlags)
		expectEqual(re2:ToString(), string.rep("x", #values), "big concat tostring")
		re2:Decref()
	end

	local named = parseOrFail("(?P<g1>a+)|(e)(?P<g2>w*)+(?P<g1>b+)", Regexp.PerlX, "named captures")
	if named ~= nil then
		expectEqual(named:NumCaptures(), 4, "num captures")
		local have = named:NamedCaptures()
		expectEqual(have.g1, 1, "named captures g1")
		expectEqual(have.g2, 3, "named captures g2")
		local byIndex = named:CaptureNames()
		expectEqual(byIndex[1], "g1", "capture names[1]")
		expectEqual(byIndex[3], "g2", "capture names[3]")
		expectEqual(byIndex[4], "g1", "capture names[4]")
	end
end

local function runSimplifyTests()
	local fixtures = Fixtures.loadSimplifyFixtures()
	local flags = bit32.bor(Regexp.MatchNL, bit32.band(Regexp.LikePerl, bit32.bnot(Regexp.OneLine)))
	for _, case in ipairs(fixtures.tests) do
		local re = parseOrFail(case.regexp, flags, "simplify " .. case.regexp)
		if re ~= nil then
			local simplified = re:Simplify()
			expectEqual(simplified:ToString(), case.parse, "simplify output for " .. case.regexp)
			if case.regexp == case.parse and simplified ~= re then
				fail("expected simplify to return original object for " .. case.regexp)
			end
		end
	end
end

runParseTests()
runPCRE2Tests()
runPCRE2CorpusSmokeTests()
runMatchEngineTests()
runGrepModuleTests()
runCharClassTests()
runRegexpTests()
runSimplifyTests()

if #failures > 0 then
	print(string.format("FAILED: %d checks", #failures))
	for _, message in ipairs(failures) do
		print("")
		print(message)
	end
	error("test failures")
end

print("All parser tests passed.")
