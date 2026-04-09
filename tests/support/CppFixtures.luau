local fs = require("@lune/fs")

local Fixtures = {}

local function readFile(path: string): string
	return fs.readFile(path)
end

local function readFirstFile(paths: { string }): string
	local lastError = nil
	for _, path in ipairs(paths) do
		local ok, result = pcall(readFile, path)
		if ok then
			return result
		end
		lastError = result
	end
	error(tostring(lastError or ("unable to read any fixture path: " .. table.concat(paths, ", "))))
end

local function isSpace(ch: string): boolean
	return ch == " " or ch == "\t" or ch == "\r" or ch == "\n"
end

local function isIdentStart(ch: string): boolean
	return ch:match("[A-Za-z_]") ~= nil
end

local function isIdent(ch: string): boolean
	return ch:match("[A-Za-z0-9_:]") ~= nil
end

local function isHex(ch: string): boolean
	return ch:match("[0-9A-Fa-f]") ~= nil
end

local function parseCString(source: string, index: number)
	local out = {}
	index += 1

	while index <= #source do
		local ch = source:sub(index, index)
		if ch == '"' then
			return table.concat(out), index + 1
		elseif ch == "\\" then
			index += 1
			local esc = source:sub(index, index)
			if esc == "n" then
				table.insert(out, "\n")
				index += 1
			elseif esc == "r" then
				table.insert(out, "\r")
				index += 1
			elseif esc == "t" then
				table.insert(out, "\t")
				index += 1
			elseif esc == "f" then
				table.insert(out, "\f")
				index += 1
			elseif esc == "v" then
				table.insert(out, "\v")
				index += 1
			elseif esc == "a" then
				table.insert(out, string.char(0x07))
				index += 1
			elseif esc == "\\" or esc == '"' or esc == "'" then
				table.insert(out, esc)
				index += 1
			elseif esc == "x" then
				index += 1
				local start = index
				while index <= #source and isHex(source:sub(index, index)) do
					index += 1
				end
				local hex = source:sub(start, index - 1)
				table.insert(out, string.char(tonumber(hex, 16)))
			else
				table.insert(out, esc)
				index += 1
			end
		else
			table.insert(out, ch)
			index += 1
		end
	end

	error("unterminated C string")
end

local function tokenize(source: string)
	local tokens = {}
	local index = 1

	while index <= #source do
		local ch = source:sub(index, index)
		local nextTwo = source:sub(index, index + 1)

		if isSpace(ch) then
			index += 1
		elseif nextTwo == "//" then
			local newline = string.find(source, "\n", index + 2, true)
			if newline == nil then
				break
			end
			index = newline + 1
		elseif nextTwo == "/*" then
			local close = assert(string.find(source, "*/", index + 2, true))
			index = close + 2
		elseif ch == '"' then
			local value
			value, index = parseCString(source, index)
			table.insert(tokens, { kind = "string", value = value })
		elseif isIdentStart(ch) then
			local start = index
			index += 1
			while index <= #source and isIdent(source:sub(index, index)) do
				index += 1
			end
			table.insert(tokens, { kind = "ident", value = source:sub(start, index - 1) })
		elseif ch:match("[%-%d]") then
			local start = index
			index += 1
			while index <= #source and source:sub(index, index):match("%d") do
				index += 1
			end
			table.insert(tokens, { kind = "number", value = tonumber(source:sub(start, index - 1)) })
		else
			table.insert(tokens, { kind = ch, value = ch })
			index += 1
		end
	end

	return tokens
end

local function findArray(tokens, name)
	for index, token in ipairs(tokens) do
		if token.kind == "ident" and token.value == name then
			local scan = index + 1
			while scan <= #tokens and tokens[scan].kind ~= "=" do
				scan += 1
			end
			if scan <= #tokens and tokens[scan + 1] and tokens[scan + 1].kind == "{" then
				return scan + 1
			end
		end
	end
	error("array not found: " .. name)
end

local function mapFlag(flagName, Regexp)
	if flagName == "TestZeroFlags" then
		return Regexp.WasDollar
	end
	local stripped = flagName:gsub("Regexp::", "")
	return Regexp[stripped] or 0
end

local function parseFlagExpr(tokens, index, Regexp)
	local value = 0
	while index <= #tokens do
		local token = tokens[index]
		if token.kind == "}" or token.kind == "," then
			break
		end
		if token.kind == "ident" then
			value = bit32.bor(value, mapFlag(token.value, Regexp))
		end
		index += 1
	end
	return value, index
end

local function parseTestArray(tokens, index, Regexp)
	local out = {}
	index += 1
	while tokens[index] and tokens[index].kind ~= "}" do
		assert(tokens[index].kind == "{")
		index += 1

		local regexp = tokens[index].value
		index += 1
		assert(tokens[index].kind == ",")
		index += 1

		local parse = ""
		while tokens[index].kind == "string" do
			parse ..= tokens[index].value
			index += 1
		end

		local flags = 0
		if tokens[index].kind == "," then
			index += 1
			flags, index = parseFlagExpr(tokens, index, Regexp)
		end

		assert(tokens[index].kind == "}")
		index += 1
		if tokens[index] and tokens[index].kind == "," then
			index += 1
		end

		table.insert(out, { regexp = regexp, parse = parse, flags = flags })
	end
	return out
end

local function parseStringArray(tokens, index)
	local out = {}
	index += 1
	while tokens[index] and tokens[index].kind ~= "}" do
		assert(tokens[index].kind == "string")
		table.insert(out, tokens[index].value)
		index += 1
		if tokens[index] and tokens[index].kind == "," then
			index += 1
		end
	end
	return out
end

local function parseRangeList(tokens, index)
	local function readValue(token)
		if token.kind == "number" then
			return token.value
		elseif token.kind == "ident" and token.value == "Runemax" then
			return 0x10FFFF
		end
		error("unexpected range token: " .. tostring(token.value))
	end

	local out = {}
	assert(tokens[index].kind == "{")
	index += 1
	while tokens[index] and tokens[index].kind ~= "}" do
		assert(tokens[index].kind == "{")
		index += 1
		local first = readValue(tokens[index])
		index += 1
		local second = nil
		if tokens[index].kind == "," then
			index += 1
			second = readValue(tokens[index])
			index += 1
		end
		assert(tokens[index].kind == "}")
		index += 1
		if tokens[index] and tokens[index].kind == "," then
			index += 1
		end
		if second == nil then
			break
		end
		table.insert(out, { lo = first, hi = second })
	end
	assert(tokens[index].kind == "}")
	return out, index + 1
end

local function parseCharClassTests(tokens, index)
	local function readValue(token)
		if token.kind == "number" then
			return token.value
		elseif token.kind == "ident" and token.value == "Runemax" then
			return 0x10FFFF
		end
		error("unexpected charclass token: " .. tostring(token.value))
	end

	local out = {}
	index += 1
	while tokens[index] and tokens[index].kind ~= "}" do
		assert(tokens[index].kind == "{")
		index += 1
		local add, nextIndex = parseRangeList(tokens, index)
		index = nextIndex
		assert(tokens[index].kind == ",")
		index += 1
		local remove = readValue(tokens[index])
		index += 1
		assert(tokens[index].kind == ",")
		index += 1
		local final
		final, index = parseRangeList(tokens, index)
		assert(tokens[index].kind == "}")
		index += 1
		if tokens[index] and tokens[index].kind == "," then
			index += 1
		end
		table.insert(out, {
			add = add,
			remove = remove,
			final = final,
		})
	end
	return out
end

local function extractSlashDelimitedPattern(line: string): string?
	if string.sub(line, 1, 1) ~= "/" then
		return nil
	end

	local escaped = false
	local inClass = false
	for index = 2, #line do
		local ch = string.sub(line, index, index)
		if escaped then
			escaped = false
		elseif ch == "\\" then
			escaped = true
		elseif ch == "[" then
			inClass = true
		elseif ch == "]" then
			inClass = false
		elseif ch == "/" and not inClass then
			return string.sub(line, 2, index - 1)
		end
	end

	return nil
end

function Fixtures.loadParseFixtures(Regexp)
	local tokens = tokenize(readFirstFile({
		"tests/data/RE2/parse_test.cc",
		"testing/RE2/parse_test.cc",
		"testing/parse_test.cc",
	}))
	return {
		tests = parseTestArray(tokens, findArray(tokens, "tests"), Regexp),
		foldcase_tests = parseTestArray(tokens, findArray(tokens, "foldcase_tests"), Regexp),
		literal_tests = parseTestArray(tokens, findArray(tokens, "literal_tests"), Regexp),
		matchnl_tests = parseTestArray(tokens, findArray(tokens, "matchnl_tests"), Regexp),
		nomatchnl_tests = parseTestArray(tokens, findArray(tokens, "nomatchnl_tests"), Regexp),
		prefix_tests = parseTestArray(tokens, findArray(tokens, "prefix_tests"), Regexp),
		nested_tests = parseTestArray(tokens, findArray(tokens, "nested_tests"), Regexp),
		badtests = parseStringArray(tokens, findArray(tokens, "badtests")),
		only_perl = parseStringArray(tokens, findArray(tokens, "only_perl")),
		only_posix = parseStringArray(tokens, findArray(tokens, "only_posix")),
	}
end

function Fixtures.loadSimplifyFixtures()
	local tokens = tokenize(readFirstFile({
		"tests/data/RE2/simplify_test.cc",
		"testing/RE2/simplify_test.cc",
		"testing/simplify_test.cc",
	}))
	return {
		tests = parseTestArray(tokens, findArray(tokens, "tests"), { }),
	}
end

function Fixtures.loadCharClassFixtures()
	local tokens = tokenize(readFirstFile({
		"tests/data/RE2/charclass_test.cc",
		"testing/RE2/charclass_test.cc",
		"testing/charclass_test.cc",
	}))
	return {
		tests = parseCharClassTests(tokens, findArray(tokens, "tests")),
	}
end

function Fixtures.loadPCRE2Patterns()
	local cases = {}
	for index = 1, 29 do
		local path = string.format("tests/data/PCRE2/testdata/testinput%d", index)
		local ok, source = pcall(readFile, path)
		if not ok then
			path = string.format("testing/PCRE2/testdata/testinput%d", index)
			ok, source = pcall(readFile, path)
		end
		if ok then
			local lineNumber = 0
			for rawLine in string.gmatch(source, "([^\n]*)\n?") do
				lineNumber += 1
				local line = string.gsub(rawLine, "\r$", "")
				local pattern = extractSlashDelimitedPattern(line)
				if pattern ~= nil then
					table.insert(cases, {
						file = path,
						line = lineNumber,
						regexp = pattern,
					})
				end
			end
		end
	end

	return {
		cases = cases,
	}
end

return Fixtures
