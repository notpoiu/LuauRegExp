local process = require("@lune/process")
local fs = require("@lune/fs")
local Regexp = require("../src/Regexp")
local Grep = require("../src/Grep")
local CharClass = require("../src/regexp/CharClass")
local Fixtures = require("../tests/support/CppFixtures")

local function parseArgs()
	local options = {
		minSeconds = 0.15,
		samples = 5,
		warmup = 2,
	}

	local args = process.args
	local index = 1
	while index <= #args do
		local arg = args[index]
		if arg == "--min-seconds" and args[index + 1] ~= nil then
			options.minSeconds = tonumber(args[index + 1]) or options.minSeconds
			index += 2
		elseif arg == "--samples" and args[index + 1] ~= nil then
			options.samples = tonumber(args[index + 1]) or options.samples
			index += 2
		elseif arg == "--warmup" and args[index + 1] ~= nil then
			options.warmup = tonumber(args[index + 1]) or options.warmup
			index += 2
		else
			index += 1
		end
	end

	return options
end

local function collectParseCorpus()
	local fixtures = Fixtures.loadParseFixtures(Regexp)
	local kTestFlags = bit32.bor(Regexp.MatchNL, Regexp.PerlX, Regexp.PerlClasses, Regexp.UnicodeGroups)
	local corpus = {}
	local groups = {
		{ cases = fixtures.tests, flags = kTestFlags },
		{ cases = fixtures.foldcase_tests, flags = Regexp.FoldCase },
		{ cases = fixtures.literal_tests, flags = Regexp.Literal },
		{ cases = fixtures.matchnl_tests, flags = Regexp.MatchNL },
		{ cases = fixtures.nomatchnl_tests, flags = Regexp.NoParseFlags },
		{ cases = fixtures.prefix_tests, flags = Regexp.PerlX },
		{ cases = fixtures.nested_tests, flags = Regexp.PerlX },
	}

	for _, group in ipairs(groups) do
		for _, case in ipairs(group.cases) do
			local flags = group.flags
			if case.flags ~= 0 then
				flags = bit32.band(case.flags, bit32.bnot(Regexp.WasDollar))
			end
			table.insert(corpus, {
				regexp = case.regexp,
				flags = flags,
			})
		end
	end

	for _, case in ipairs({
		{ regexp = "(?=foo)bar", flags = Regexp.LikePCRE2 },
		{ regexp = "(?<=foo)bar", flags = Regexp.LikePCRE2 },
		{ regexp = "(?>ab|ac)d", flags = Regexp.LikePCRE2 },
		{ regexp = "a{2,4}+", flags = Regexp.LikePCRE2 },
		{ regexp = "([a-z]+)\\1", flags = Regexp.LikePCRE2 },
		{ regexp = "(?<word>[a-z]+)\\k<word>", flags = Regexp.LikePCRE2 },
		{ regexp = "(?P<word>[a-z]+)(?P=word)", flags = Regexp.LikePCRE2 },
	}) do
		table.insert(corpus, case)
	end

	for _, case in ipairs({
		{ regexp = "a|aa|aaa|aaaa|aaaaa|aaaaaa|aaaaaaa|aaaaaaaa|aaaaaaaaa|aaaaaaaaaa", flags = Regexp.PerlX },
		{ regexp = "a|aardvark|aardvarks|abaci|aback|abacus|abacuses|abaft|abalone|abalones", flags = Regexp.PerlX },
		{ regexp = string.rep("(ab|cd|ef|gh)", 16), flags = Regexp.PerlX },
		{ regexp = string.rep("x{2}", 20), flags = Regexp.PerlX },
		{ regexp = string.rep("((ab){2}|(cd){3})", 8), flags = Regexp.PerlX },
	}) do
		table.insert(corpus, case)
	end

	return corpus
end

local function prepareParsedCorpus(corpus)
	local parsed = {}
	for _, case in ipairs(corpus) do
		local status = Regexp.newStatus()
		local re = Regexp.Parse(case.regexp, case.flags, status)
		assert(re ~= nil, string.format("benchmark setup parse failed for %s: %s", case.regexp, status:Text()))
		table.insert(parsed, {
			regexp = case.regexp,
			flags = case.flags,
			re = re,
		})
	end
	return parsed
end

local function collectSimplifyCorpus()
	local fixtures = Fixtures.loadSimplifyFixtures()
	local flags = bit32.bor(Regexp.MatchNL, bit32.band(Regexp.LikePerl, bit32.bnot(Regexp.OneLine)))
	local corpus = {}
	for _, case in ipairs(fixtures.tests) do
		local status = Regexp.newStatus()
		local re = Regexp.Parse(case.regexp, flags, status)
		assert(re ~= nil, string.format("simplify benchmark setup parse failed for %s: %s", case.regexp, status:Text()))
		table.insert(corpus, re)
	end
	return corpus
end

local function collectCharClassCorpus()
	local fixtures = Fixtures.loadCharClassFixtures()
	return fixtures.tests
end

local CODE_FILE_EXTENSIONS = {
	[".c"] = true,
	[".cc"] = true,
	[".cpp"] = true,
	[".cs"] = true,
	[".css"] = true,
	[".go"] = true,
	[".h"] = true,
	[".hpp"] = true,
	[".html"] = true,
	[".java"] = true,
	[".js"] = true,
	[".json"] = true,
	[".jsx"] = true,
	[".lua"] = true,
	[".luau"] = true,
	[".md"] = true,
	[".mjs"] = true,
	[".py"] = true,
	[".rb"] = true,
	[".rs"] = true,
	[".sh"] = true,
	[".sql"] = true,
	[".toml"] = true,
	[".ts"] = true,
	[".tsx"] = true,
	[".txt"] = true,
	[".xml"] = true,
	[".yaml"] = true,
	[".yml"] = true,
}

local GREP_QUERY_CORPUS = {
	{ regexp = "TODO|FIXME|BUG", flags = Regexp.NoParseFlags },
	{ regexp = "\\bfunction\\b", flags = Regexp.LikePerl },
	{ regexp = "\\blocal\\s+[A-Za-z_][A-Za-z0-9_]*", flags = Regexp.LikePerl },
	{ regexp = "\\breturn\\b", flags = Regexp.LikePerl },
	{ regexp = "\\bif\\b.*\\bthen\\b", flags = Regexp.LikePerl },
	{ regexp = "\\bclass\\s+[A-Za-z_][A-Za-z0-9_]*", flags = Regexp.LikePerl },
	{ regexp = "\\binterface\\b", flags = Regexp.LikePerl },
	{ regexp = "\\basync\\s+function\\b", flags = Regexp.LikePerl },
	{ regexp = "\\buseState\\b|\\buseEffect\\b", flags = Regexp.LikePerl },
	{ regexp = "\\bRemoteEvent\\b|\\bRemoteFunction\\b", flags = Regexp.LikePerl },
	{ regexp = "\\bexecutor\\b|\\bidentifyexecutor\\b", flags = Regexp.LikePerl },
	{ regexp = "^[ \t]*export\\s+", flags = Regexp.LikePerl },
	{ regexp = "^[ \t]*import\\s+", flags = Regexp.LikePerl },
	{ regexp = "\\bmatch\\s*\\(", flags = Regexp.LikePerl },
	{ regexp = "\\bregex\\b|\\bregexp\\b", flags = Regexp.LikePerl },
	{ regexp = "(?<name>[A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*function", flags = Regexp.LikePCRE2 },
	{ regexp = "(?i)license|copyright", flags = Regexp.LikePerl },
	{ regexp = "(?=.{0,120}error).+", flags = Regexp.LikePCRE2 },
	{ regexp = "(?>[A-Za-z_][A-Za-z0-9_]*)\\(", flags = Regexp.LikePCRE2 },
	{ regexp = "([A-Za-z_][A-Za-z0-9_]*)\\1", flags = Regexp.LikePCRE2 },
}

local function fileExtension(path)
	return string.match(path, "%.([^.\\/]+)$")
end

local function joinPath(base, child)
	if string.sub(base, -1) == "/" then
		return base .. child
	end
	return base .. "/" .. child
end

local function collectCodebaseCorpus(root)
	local files = {}
	local repos = {}
	local totalBytes = 0

	local function walk(path, repoName)
		for _, entry in ipairs(fs.readDir(path)) do
			local fullPath = joinPath(path, entry)
			local metadata = fs.metadata(fullPath)
			if metadata.exists then
				if metadata.kind == "dir" then
					walk(fullPath, repoName)
				elseif metadata.kind == "file" then
					local ext = fileExtension(fullPath)
					if ext ~= nil and CODE_FILE_EXTENSIONS["." .. string.lower(ext)] then
						local source = fs.readFile(fullPath)
						local size = #source
						table.insert(files, {
							path = fullPath,
							repo = repoName,
							size = size,
							source = source,
						})
						totalBytes += size
					end
				end
			end
		end
	end

	for _, entry in ipairs(fs.readDir(root)) do
		local path = joinPath(root, entry)
		local metadata = fs.metadata(path)
		if metadata.exists and metadata.kind == "dir" then
			table.insert(repos, {
				name = entry,
				path = path,
			})
			walk(path, entry)
		end
	end

	table.sort(repos, function(a, b)
		return a.name < b.name
	end)
	table.sort(files, function(a, b)
		if a.repo == b.repo then
			return a.path < b.path
		end
		return a.repo < b.repo
	end)

	return {
		root = root,
		repos = repos,
		files = files,
		totalBytes = totalBytes,
		totalMiB = totalBytes / (1024 * 1024),
	}
end

local function prepareCodebaseQueries()
	local prepared = {}
	for _, case in ipairs(GREP_QUERY_CORPUS) do
		local status = Regexp.newStatus()
		local re = Regexp.Parse(case.regexp, case.flags, status)
		assert(re ~= nil, string.format("grep query setup parse failed for %s: %s", case.regexp, status:Text()))
		table.insert(prepared, {
			regexp = case.regexp,
			flags = case.flags,
			re = re,
		})
	end
	return prepared
end

local function selectGrepBenchmarkCorpus(codebaseCorpus)
	local maxFiles = 120
	local maxFileBytes = 256 * 1024
	local files = {}
	local totalBytes = 0

	for _, file in ipairs(codebaseCorpus.files) do
		if file.size <= maxFileBytes then
			table.insert(files, file)
			totalBytes += file.size
			if #files >= maxFiles then
				break
			end
		end
	end

	if #files == 0 then
		for index = 1, math.min(#codebaseCorpus.files, maxFiles) do
			local file = codebaseCorpus.files[index]
			table.insert(files, file)
			totalBytes += file.size
		end
	end

	return {
		files = files,
		totalBytes = totalBytes,
		totalMiB = totalBytes / (1024 * 1024),
		maxFiles = maxFiles,
		maxFileBytes = maxFileBytes,
		skippedFiles = #codebaseCorpus.files - #files,
	}
end

local function mean(values)
	local total = 0
	for _, value in ipairs(values) do
		total += value
	end
	return total / #values
end

local function minmax(values)
	local minimum = values[1]
	local maximum = values[1]
	for index = 2, #values do
		local value = values[index]
		if value < minimum then
			minimum = value
		end
		if value > maximum then
			maximum = value
		end
	end
	return minimum, maximum
end

local function benchmarkCase(name, unitCount, fn, options)
	for _ = 1, options.warmup do
		fn()
	end

	local iterations = 1
	while true do
		local start = os.clock()
		for _ = 1, iterations do
			fn()
		end
		local elapsed = os.clock() - start
		if elapsed >= options.minSeconds or iterations >= 1_000_000 then
			break
		end
		iterations *= 2
	end

	local totals = {}
	for _ = 1, options.samples do
		local start = os.clock()
		for _ = 1, iterations do
			fn()
		end
		table.insert(totals, os.clock() - start)
	end

	local perIteration = {}
	local perUnit = {}
	for _, total in ipairs(totals) do
		table.insert(perIteration, total / iterations)
		table.insert(perUnit, total / (iterations * unitCount))
	end

	local avgIteration = mean(perIteration)
	local avgUnit = mean(perUnit)
	local minUnit, maxUnit = minmax(perUnit)

	return {
		name = name,
		iterations = iterations,
		samples = options.samples,
		unitCount = unitCount,
		meanIterationSeconds = avgIteration,
		meanUnitSeconds = avgUnit,
		minUnitSeconds = minUnit,
		maxUnitSeconds = maxUnit,
		unitsPerSecond = 1 / avgUnit,
	}
end

local function formatRate(rate)
	if rate >= 1_000_000 then
		return string.format("%.2fM/s", rate / 1_000_000)
	elseif rate >= 1_000 then
		return string.format("%.2fK/s", rate / 1_000)
	end
	return string.format("%.2f/s", rate)
end

local function formatUnitSeconds(seconds)
	local microseconds = seconds * 1_000_000
	if microseconds >= 1000 then
		return string.format("%.2f ms", microseconds / 1000)
	end
	return string.format("%.2f us", microseconds)
end

local function formatMiB(value)
	return string.format("%.2f MiB", value)
end

local function run()
	local options = parseArgs()
	local parseCorpus = collectParseCorpus()
	local parsedCorpus = prepareParsedCorpus(parseCorpus)
	local simplifyCorpus = collectSimplifyCorpus()
	local charClassCorpus = collectCharClassCorpus()
	local codebaseCorpus = collectCodebaseCorpus("benchmarks/data/codebases")
	local preparedCodebaseQueries = prepareCodebaseQueries()
	local grepBenchmarkCorpus = selectGrepBenchmarkCorpus(codebaseCorpus)

	local results = {}

	table.insert(results, benchmarkCase("Parse corpus", #parseCorpus, function()
		for _, case in ipairs(parseCorpus) do
			local status = Regexp.newStatus()
			local re = Regexp.Parse(case.regexp, case.flags, status)
			assert(re ~= nil, status:Text())
		end
	end, options))

	table.insert(results, benchmarkCase("Dump parsed ASTs", #parsedCorpus, function()
		for _, case in ipairs(parsedCorpus) do
			case.re:Dump()
		end
	end, options))

	table.insert(results, benchmarkCase("ToString parsed ASTs", #parsedCorpus, function()
		for _, case in ipairs(parsedCorpus) do
			case.re:ToString()
		end
	end, options))

	table.insert(results, benchmarkCase("Simplify corpus", #simplifyCorpus, function()
		for _, re in ipairs(simplifyCorpus) do
			re:Simplify()
		end
	end, options))

	table.insert(results, benchmarkCase("Parse+Dump+ToString end-to-end", #parseCorpus, function()
		for _, case in ipairs(parseCorpus) do
			local status = Regexp.newStatus()
			local re = Regexp.Parse(case.regexp, case.flags, status)
			assert(re ~= nil, status:Text())
			re:Dump()
			re:ToString()
		end
	end, options))

	table.insert(results, benchmarkCase("CharClass builder ops", #charClassCorpus, function()
		for _, case in ipairs(charClassCorpus) do
			local cc = CharClass.new()
			for _, range in ipairs(case.add) do
				cc:addRange(range.lo, range.hi)
			end
			if case.remove >= 0 then
				cc:removeAbove(case.remove)
			end
			local neg = cc:negate()
			neg:contains(0x10FFFF)
			cc:contains(97)
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep query compile", #GREP_QUERY_CORPUS, function()
		for _, case in ipairs(GREP_QUERY_CORPUS) do
			local status = Regexp.newStatus()
			local re = Regexp.Parse(case.regexp, case.flags, status)
			assert(re ~= nil, status:Text())
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep session setup", #codebaseCorpus.repos, function()
		for _ = 1, #codebaseCorpus.repos do
			for _, case in ipairs(GREP_QUERY_CORPUS) do
				local status = Regexp.newStatus()
				local re = Regexp.Parse(case.regexp, case.flags, status)
				assert(re ~= nil, status:Text())
			end
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep compile amortized by source file", #grepBenchmarkCorpus.files, function()
		for _ = 1, #grepBenchmarkCorpus.files do
			for _, case in ipairs(GREP_QUERY_CORPUS) do
				local status = Regexp.newStatus()
				local re = Regexp.Parse(case.regexp, case.flags, status)
				assert(re ~= nil, status:Text())
			end
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep execute first hit (compiled, line mode)", #preparedCodebaseQueries * #grepBenchmarkCorpus.files, function()
		for _, query in ipairs(preparedCodebaseQueries) do
			for _, file in ipairs(grepBenchmarkCorpus.files) do
				local matches, err = Grep.searchText(query.re, file.source, {
					maxMatches = 1,
				})
				assert(matches ~= nil, tostring(err))
			end
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep execute all hits (compiled, line mode)", #preparedCodebaseQueries * #grepBenchmarkCorpus.files, function()
		for _, query in ipairs(preparedCodebaseQueries) do
			for _, file in ipairs(grepBenchmarkCorpus.files) do
				local matches, err = Grep.searchText(query.re, file.source, {
					maxMatches = 100,
				})
				assert(matches ~= nil, tostring(err))
			end
		end
	end, options))

	table.insert(results, benchmarkCase("Codebase grep end-to-end per query", #preparedCodebaseQueries, function()
		for _, query in ipairs(GREP_QUERY_CORPUS) do
			local status = Regexp.newStatus()
			local re = Regexp.Parse(query.regexp, query.flags, status)
			assert(re ~= nil, status:Text())
			for _, file in ipairs(grepBenchmarkCorpus.files) do
				local matches, err = Grep.searchText(re, file.source, {
					maxMatches = 1,
				})
				assert(matches ~= nil, tostring(err))
			end
		end
	end, options))

	print(string.format(
		"Benchmark corpus: %d parse patterns, %d simplify patterns, %d charclass cases",
		#parseCorpus,
		#simplifyCorpus,
		#charClassCorpus
	))
	print(string.format(
		"Benchmark config: minSeconds=%.2f samples=%d warmup=%d",
		options.minSeconds,
		options.samples,
		options.warmup
	))
	print(string.format(
		"Codebase corpus: %d repos, %d source files, %s",
		#codebaseCorpus.repos,
		#codebaseCorpus.files,
		formatMiB(codebaseCorpus.totalMiB)
	))
	print(string.format(
		"Codebase grep subset: %d queries, %d files, %s (<= %d KiB each, skipped %d files)",
		#GREP_QUERY_CORPUS,
		#grepBenchmarkCorpus.files,
		formatMiB(grepBenchmarkCorpus.totalMiB),
		math.floor(grepBenchmarkCorpus.maxFileBytes / 1024),
		grepBenchmarkCorpus.skippedFiles
	))
	print(string.format(
		"Codebase grep execution units: %d file-query pairs",
		#preparedCodebaseQueries * #grepBenchmarkCorpus.files
	))
	print("")

	for _, result in ipairs(results) do
		print(result.name)
		print(string.format("  unit count:    %d", result.unitCount))
		print(string.format("  sample iters:  %d", result.iterations))
		print(string.format("  mean/unit:     %s", formatUnitSeconds(result.meanUnitSeconds)))
		print(string.format("  min..max/unit: %s .. %s", formatUnitSeconds(result.minUnitSeconds), formatUnitSeconds(result.maxUnitSeconds)))
		print(string.format("  throughput:    %s", formatRate(result.unitsPerSecond)))
		print("")
	end
end

run()
