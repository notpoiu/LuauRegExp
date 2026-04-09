local Regexp = require("./Regexp")

local Grep = {}

local DEFAULT_CODE_EXTENSIONS = {
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

-- fs is lazy-loaded only when searchPath is called (not available in Roblox)
local fs = nil
local function requireFs()
	if fs == nil then
		fs = require("@lune/fs")
	end
	return fs
end

local function joinPath(base: string, child: string): string
	if string.sub(base, -1) == "/" then
		return base .. child
	end
	return base .. "/" .. child
end

local function normalizeExtensions(extensions)
	if extensions == false then
		return nil
	end

	local out = {}
	local source = extensions or DEFAULT_CODE_EXTENSIONS
	if extensions == nil then
		return source
	end

	for _, extension in ipairs(source) do
		if type(extension) == "string" then
			if string.sub(extension, 1, 1) ~= "." then
				extension = "." .. extension
			end
			out[string.lower(extension)] = true
		end
	end
	return out
end

local function fileAllowed(path: string, extensions): boolean
	if extensions == nil then
		return true
	end
	local extension = string.match(path, "(%.[^./\\]+)$")
	if extension == nil then
		return false
	end
	return extensions[string.lower(extension)] == true
end

local function buildLineStarts(text: string)
	local starts = { 1 }
	local index = 1
	while true do
		local newline = string.find(text, "\n", index, true)
		if newline == nil then
			break
		end
		table.insert(starts, newline + 1)
		index = newline + 1
	end
	return starts
end

local function lineForByte(starts, byteIndex: number)
	local lo = 1
	local hi = #starts
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if starts[mid] <= byteIndex then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

local function lineText(text: string, starts, line: number): string
	local startByte = starts[line]
	local finishByte = starts[line + 1]
	if finishByte == nil then
		return string.gsub(string.sub(text, startByte), "\n$", "")
	end
	return string.gsub(string.sub(text, startByte, finishByte - 2), "\n$", "")
end

local function enrichMatches(path: string?, text: string, matches)
	local starts = buildLineStarts(text)
	for _, match in ipairs(matches) do
		local line = lineForByte(starts, match.start)
		if path ~= nil then
			match.path = path
		end
		match.line = line
		match.column = match.start - starts[line] + 1
		match.lineText = lineText(text, starts, line)
	end
	return matches
end

local function searchTextWhole(re, text: string, options)
	local matches, searchErr = re:FindAll(text, options.maxMatches, options.startByte)
	if matches == nil then
		return nil, searchErr
	end
	return enrichMatches(options.path, text, matches), nil
end

local function searchTextByLine(re, text: string, options)
	local subject, subjectErr = Regexp.PrepareSubject(text, re.latin1 or false)
	if subject == nil then
		return nil, subjectErr
	end

	local results = {}
	local maxMatches = options.maxMatches or math.huge
	local lineNumber = 1
	local lineStart = 1
	local startByte = options.startByte

	-- Build a rune-position lookup: for each line, find the start/end rune positions
	-- For ASCII subjects, byte pos == rune pos, so this is trivial
	local isAscii = subject.isAscii

	while lineStart <= #text + 1 and #results < maxMatches do
		local newline = string.find(text, "\n", lineStart, true)
		local lineEnd = if newline == nil then #text else newline - 1

		if startByte == nil or startByte <= lineEnd + 1 then
			local lineStartByte = lineStart
			if startByte ~= nil then
				lineStartByte = math.max(lineStart, startByte)
				startByte = nil
			end

			-- Convert byte positions to rune positions for the subject
			local startRunePos, endRunePos
			if isAscii then
				startRunePos = lineStartByte
				endRunePos = lineEnd
			else
				startRunePos = nil
				endRunePos = nil
				-- Binary search for start rune pos
				local lo, hi = 1, subject.runeCount + 1
				while lo < hi do
					local mid = math.floor((lo + hi) / 2)
					if subject.bytePositions[mid] < lineStartByte then
						lo = mid + 1
					else
						hi = mid
					end
				end
				startRunePos = lo
				-- Binary search for end rune pos (last rune on this line)
				lo, hi = startRunePos, subject.runeCount
				while lo < hi do
					local mid = math.floor((lo + hi + 1) / 2)
					if subject.bytePositions[mid] <= lineEnd then
						lo = mid
					else
						hi = mid - 1
					end
				end
				endRunePos = lo
			end

			local matches, searchErr = re:FindAllPrepared(subject, maxMatches - #results, startRunePos, endRunePos)
			if matches == nil then
				return nil, searchErr
			end

			if #matches > 0 then
				local fullLineText = string.sub(text, lineStart, lineEnd)
				local path = options.path
				for _, match in ipairs(matches) do
					match.line = lineNumber
					match.column = match.start - lineStart + 1
					match.lineText = fullLineText
					if path ~= nil then
						match.path = path
					end
					table.insert(results, match)
				end
			end
		end

		if newline == nil then
			break
		end

		lineStart = newline + 1
		lineNumber += 1
	end

	return results, nil
end

local function ensureRegexp(patternOrRegexp, flags, status)
	if type(patternOrRegexp) == "table" and patternOrRegexp.kind ~= nil then
		return patternOrRegexp, nil
	end
	local re = Regexp.Parse(patternOrRegexp, flags or 0, status)
	if re == nil then
		return nil, status ~= nil and status:Text() or "parse failed"
	end
	return re, nil
end

function Grep.searchText(patternOrRegexp, text: string, options)
	options = options or {}
	local status = Regexp.newStatus()
	local re, err = ensureRegexp(patternOrRegexp, options.flags, status)
	if re == nil then
		return nil, err
	end

	if options.lineMode == false then
		return searchTextWhole(re, text, options)
	end

	return searchTextByLine(re, text, options)
end

-- Search an array of in-memory files. Each entry should have:
--   name: string (identifier, e.g. script path)
--   source: string (text content to search)
function Grep.searchFiles(files, patternOrRegexp, options)
	options = options or {}

	local status = Regexp.newStatus()
	local re, err = ensureRegexp(patternOrRegexp, options.flags, status)
	if re == nil then
		return nil, err
	end

	local maxMatches = options.maxMatches or math.huge
	local maxMatchesPerFile = options.maxMatchesPerFile or math.huge

	local results = {}
	local totalMatches = 0
	local searchedFiles = 0

	for _, file in ipairs(files) do
		if totalMatches >= maxMatches then
			break
		end

		searchedFiles += 1
		local remaining = math.min(maxMatchesPerFile, maxMatches - totalMatches)
		local matches, searchErr = Grep.searchText(re, file.source, {
			lineMode = options.lineMode,
			maxMatches = remaining,
			path = file.name,
		})
		if matches == nil then
			continue
		end
		if #matches == 0 then
			continue
		end

		table.insert(results, {
			path = file.name,
			matchCount = #matches,
			matches = matches,
		})
		totalMatches += #matches
	end

	return {
		pattern = re:ToString(),
		totalMatches = totalMatches,
		fileCount = #results,
		searchedFiles = searchedFiles,
		results = results,
	}, nil
end

-- Search a filesystem directory. Requires @lune/fs (not available in Roblox).
function Grep.searchPath(rootPath: string, patternOrRegexp, options)
	local lfs = requireFs()
	options = options or {}

	local status = Regexp.newStatus()
	local re, err = ensureRegexp(patternOrRegexp, options.flags, status)
	if re == nil then
		return nil, err
	end

	local extensions = normalizeExtensions(options.extensions)
	local includeHidden = options.includeHidden ~= false
	local maxMatches = options.maxMatches or math.huge
	local maxMatchesPerFile = options.maxMatchesPerFile or math.huge

	local results = {}
	local totalMatches = 0
	local searchedFiles = 0
	local skippedFiles = 0

	local function walk(path: string)
		if totalMatches >= maxMatches then
			return
		end

		local metadata = lfs.metadata(path)
		if not metadata.exists then
			return
		end

		if metadata.kind == "dir" then
			for _, entry in ipairs(lfs.readDir(path)) do
				if not includeHidden and string.sub(entry, 1, 1) == "." then
					continue
				end
				walk(joinPath(path, entry))
				if totalMatches >= maxMatches then
					return
				end
			end
			return
		end

		if metadata.kind ~= "file" or not fileAllowed(path, extensions) then
			return
		end

		searchedFiles += 1

		local ok, text = pcall(lfs.readFile, path)
		if not ok then
			skippedFiles += 1
			return
		end

		local remaining = math.min(maxMatchesPerFile, maxMatches - totalMatches)
		local matches, searchErr = Grep.searchText(re, text, {
			lineMode = options.lineMode,
			maxMatches = remaining,
			path = path,
		})
		if matches == nil then
			if searchErr ~= nil then
				skippedFiles += 1
			end
			return
		end
		if #matches == 0 then
			return
		end

		table.insert(results, {
			path = path,
			matchCount = #matches,
			matches = matches,
		})
		totalMatches += #matches
	end

	walk(rootPath)

	return {
		root = rootPath,
		pattern = re:ToString(),
		totalMatches = totalMatches,
		fileCount = #results,
		searchedFiles = searchedFiles,
		skippedFiles = skippedFiles,
		results = results,
	}, nil
end

return Grep
