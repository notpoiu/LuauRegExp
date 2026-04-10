local Utf8 = require("./Utf8")

local NFA = {}

-- Opcodes: consuming (advance text position)
local OP_CHAR = 1       -- [op, rune]
local OP_CLASS = 2      -- [op, classIdx]
local OP_DOT = 3        -- [op]
local OP_CHAR_FOLD = 4  -- [op, canonRune, latin1Flag]

-- Opcodes: epsilon (zero-width, don't consume)
local OP_MATCH = 5      -- [op]
local OP_JMP = 6        -- [op, target]
local OP_SPLIT = 7      -- [op, target1, target2]
local OP_SAVE = 8       -- [op, slot]
local OP_BOL = 9        -- [op]
local OP_BOT = 10       -- [op]
local OP_EOL = 11       -- [op]
local OP_EOT = 12       -- [op]
local OP_EOTZ = 13      -- [op]
local OP_WBOUND = 14    -- [op, latin1Flag]
local OP_NWBOUND = 15   -- [op, latin1Flag]

local INF = math.huge

-- ===== COMPILER =====

local function compileNode(re, code, classes, latin1)
	local kind = re.kind

	if kind == "empty" then
		return true
	end

	if kind == "literal" then
		local isLatin1 = re.latin1 or latin1
		local runes, err = Utf8.decodeAll(re.text, isLatin1)
		if runes == nil then
			return false
		end
		if re.fold then
			for _, rune in ipairs(runes) do
				local canon = Utf8.foldCanonicalRune(rune, isLatin1)
				code[#code + 1] = OP_CHAR_FOLD
				code[#code + 1] = canon
				code[#code + 1] = isLatin1
			end
		else
			for _, rune in ipairs(runes) do
				code[#code + 1] = OP_CHAR
				code[#code + 1] = rune
			end
		end
		return true
	end

	if kind == "charclass" then
		local idx = #classes + 1
		classes[idx] = re.class
		code[#code + 1] = OP_CLASS
		code[#code + 1] = idx
		return true
	end

	if kind == "dot" or kind == "byte" then
		code[#code + 1] = OP_DOT
		return true
	end

	if kind == "anchor" then
		local a = re.anchor
		if a == "bol" then
			code[#code + 1] = OP_BOL
		elseif a == "bot" then
			code[#code + 1] = OP_BOT
		elseif a == "eol" then
			code[#code + 1] = OP_EOL
		elseif a == "eot" then
			code[#code + 1] = (re.flavor == "\\z") and OP_EOTZ or OP_EOT
		else
			return false
		end
		return true
	end

	if kind == "boundary" then
		code[#code + 1] = re.word and OP_WBOUND or OP_NWBOUND
		code[#code + 1] = (re.latin1 or latin1) and true or false
		return true
	end

	if kind == "capture" then
		local startSlot = re.index * 2 - 1
		local endSlot = re.index * 2
		code[#code + 1] = OP_SAVE
		code[#code + 1] = startSlot
		if not compileNode(re.child, code, classes, latin1) then
			return false
		end
		code[#code + 1] = OP_SAVE
		code[#code + 1] = endSlot
		return true
	end

	if kind == "concat" then
		for _, child in ipairs(re.children) do
			if not compileNode(child, code, classes, latin1) then
				return false
			end
		end
		return true
	end

	if kind == "alt" then
		local children = re.children
		local n = #children
		if n == 0 then
			return true
		end
		if n == 1 then
			return compileNode(children[1], code, classes, latin1)
		end

		local jumpPatches = {}

		for i = 1, n do
			if i < n then
				-- SPLIT: try this child, or skip to next alternative
				local splitPC = #code + 1
				code[splitPC] = OP_SPLIT
				code[splitPC + 1] = splitPC + 3 -- child starts right after SPLIT
				code[splitPC + 2] = 0 -- placeholder for next alt

				if not compileNode(children[i], code, classes, latin1) then
					return false
				end

				-- JMP to end of alternation
				code[#code + 1] = OP_JMP
				code[#code + 1] = 0 -- placeholder
				jumpPatches[#jumpPatches + 1] = #code

				-- Patch SPLIT's second target to next alternative
				code[splitPC + 2] = #code + 1
			else
				-- Last alternative: just compile directly
				if not compileNode(children[i], code, classes, latin1) then
					return false
				end
			end
		end

		-- Patch all JMP targets to end of alternation
		local endPC = #code + 1
		for _, pos in ipairs(jumpPatches) do
			code[pos] = endPC
		end
		return true
	end

	if kind == "repeat" then
		if re.possessive then
			return false -- can't do possessive in NFA
		end

		local min = re.min
		local max = re.max
		local nongreedy = re.nongreedy
		local child = re.child

		-- Guard against code explosion from large unrolled repeats
		if max ~= INF and max > 200 then
			return false
		end

		-- Emit min mandatory copies
		for _ = 1, min do
			if not compileNode(child, code, classes, latin1) then
				return false
			end
		end

		if max == INF then
			-- Kleene star loop: SPLIT + child + JMP back
			local splitPC = #code + 1
			code[splitPC] = OP_SPLIT
			if nongreedy then
				code[splitPC + 1] = 0 -- placeholder: skip (exit)
				code[splitPC + 2] = splitPC + 3 -- try child
			else
				code[splitPC + 1] = splitPC + 3 -- try child
				code[splitPC + 2] = 0 -- placeholder: skip (exit)
			end

			if not compileNode(child, code, classes, latin1) then
				return false
			end

			code[#code + 1] = OP_JMP
			code[#code + 1] = splitPC -- loop back

			-- Patch exit target
			local afterPC = #code + 1
			if nongreedy then
				code[splitPC + 1] = afterPC
			else
				code[splitPC + 2] = afterPC
			end
		else
			-- Bounded optional copies: (max - min) copies of SPLIT + child
			local skipPatches = {}
			for _ = min + 1, max do
				local splitPC = #code + 1
				code[splitPC] = OP_SPLIT
				if nongreedy then
					code[splitPC + 1] = 0 -- placeholder: skip
					code[splitPC + 2] = splitPC + 3 -- try child
					skipPatches[#skipPatches + 1] = splitPC + 1
				else
					code[splitPC + 1] = splitPC + 3 -- try child
					code[splitPC + 2] = 0 -- placeholder: skip
					skipPatches[#skipPatches + 1] = splitPC + 2
				end

				if not compileNode(child, code, classes, latin1) then
					return false
				end
			end

			-- Patch all skip targets to after
			local afterPC = #code + 1
			for _, pos in ipairs(skipPatches) do
				code[pos] = afterPC
			end
		end
		return true
	end

	-- Features that cannot be compiled to NFA
	if kind == "lookaround" or kind == "atomic" or kind == "backref" or kind == "raw" then
		return false
	end

	return false
end

function NFA.compile(re)
	if re._nfaProgram ~= nil then
		return re._nfaProgram
	end

	local code = {}
	local classes = {}
	local latin1 = re.latin1 or false

	if not compileNode(re, code, classes, latin1) then
		re._nfaProgram = false
		return false
	end

	code[#code + 1] = OP_MATCH

	local program = {
		code = code,
		classes = classes,
		numSaves = (re.numCaptures or 0) * 2,
		latin1 = latin1,
		codeLen = #code,
	}

	re._nfaProgram = program
	return program
end

-- ===== EXECUTOR =====
-- Thompson NFA simulation with POSIX leftmost-longest semantics.
-- Processes each text position once for all active states simultaneously.

local function isWordRune(r, wLatin1)
	if r == nil then
		return false
	end
	if r >= 0x30 and r <= 0x39 then
		return true
	end
	if r >= 0x41 and r <= 0x5A then
		return true
	end
	if r == 0x5F then
		return true
	end
	if r >= 0x61 and r <= 0x7A then
		return true
	end
	if not wLatin1 and (r == 0x017F or r == 0x212A) then
		return true
	end
	return false
end

function NFA.search(program, subject, startPos, endPos, literalPrefix)
	local code = program.code
	local classes = program.classes
	local runes = subject.runes
	local runeCount = subject.runeCount
	local scanEnd = endPos or runeCount
	local numSaves = program.numSaves
	local hasSaves = numSaves > 0
	local codeLen = program.codeLen

	-- Thread lists: each entry is {pc, matchStart, saves}
	-- For no-capture patterns, saves is always nil (fast path)
	local clist = {}
	local nlist = {}
	local clen = 0
	local nlen = 0

	-- Generation counter for deduplication (avoids adding same PC twice per step)
	local gen = 1
	local visited = table.create(codeLen, 0)

	local function materializeSaves(saveNode)
		if not hasSaves or saveNode == nil then
			return nil
		end

		local saves = table.create(numSaves)
		local current = saveNode
		while current ~= nil do
			if saves[current.slot] == nil then
				saves[current.slot] = current.value
			end
			current = current.parent
		end
		return saves
	end

	-- addThread: follow all epsilon transitions from pc, adding consuming/MATCH
	-- instructions to the thread list. Returns updated list length.
	local function addThread(list, len, pc, mStart, saves, pos)
		if visited[pc] == gen then
			return len
		end
		visited[pc] = gen

		local op = code[pc]

		if op == OP_JMP then
			return addThread(list, len, code[pc + 1], mStart, saves, pos)
		elseif op == OP_SPLIT then
			len = addThread(list, len, code[pc + 1], mStart, saves, pos)
			return addThread(list, len, code[pc + 2], mStart, saves, pos)
		elseif op == OP_SAVE then
			if hasSaves then
				local newSaves = {
					parent = saves,
					slot = code[pc + 1],
					value = pos,
				}
				return addThread(list, len, pc + 2, mStart, newSaves, pos)
			end
			return addThread(list, len, pc + 2, mStart, saves, pos)
		elseif op == OP_BOL then
			if pos == 1 or runes[pos - 1] == 0x0A then
				return addThread(list, len, pc + 1, mStart, saves, pos)
			end
			return len
		elseif op == OP_BOT then
			if pos == 1 then
				return addThread(list, len, pc + 1, mStart, saves, pos)
			end
			return len
		elseif op == OP_EOL then
			if pos > runeCount or runes[pos] == 0x0A then
				return addThread(list, len, pc + 1, mStart, saves, pos)
			end
			return len
		elseif op == OP_EOT then
			if pos == runeCount + 1 or (pos == runeCount and runes[pos] == 0x0A) then
				return addThread(list, len, pc + 1, mStart, saves, pos)
			end
			return len
		elseif op == OP_EOTZ then
			if pos == runeCount + 1 then
				return addThread(list, len, pc + 1, mStart, saves, pos)
			end
			return len
		elseif op == OP_WBOUND then
			if isWordRune(runes[pos - 1], code[pc + 1]) ~= isWordRune(runes[pos], code[pc + 1]) then
				return addThread(list, len, pc + 2, mStart, saves, pos)
			end
			return len
		elseif op == OP_NWBOUND then
			if isWordRune(runes[pos - 1], code[pc + 1]) == isWordRune(runes[pos], code[pc + 1]) then
				return addThread(list, len, pc + 2, mStart, saves, pos)
			end
			return len
		end

		-- Consuming instruction (CHAR, CLASS, DOT, CHAR_FOLD) or MATCH
		-- Add to thread list
		len += 1
		local t = list[len]
		if t then
			t[1] = pc
			t[2] = mStart
			t[3] = saves
		else
			list[len] = { pc, mStart, saves }
		end
		return len
	end

	-- Best match found so far (POSIX: leftmost start, then longest)
	local bestStart, bestEnd, bestSaves

	-- Literal prefix fast path: use string.find to skip to candidate positions
	if literalPrefix and subject.isAscii then
		local text = subject.text
		local nextPrefixPos = string.find(text, literalPrefix, startPos, true)

		local sp = startPos
		while sp <= runeCount + 1 do
			-- Add start thread only at prefix positions (and only if no match yet)
			if bestStart == nil and sp <= scanEnd and sp == nextPrefixPos then
				if clen == 0 then
					gen += 1
				end
				clen = addThread(clist, clen, 1, sp, nil, sp)
				nextPrefixPos = string.find(text, literalPrefix, sp + 1, true)
			end

			-- Check for MATCH
			for i = 1, clen do
				local t = clist[i]
				if code[t[1]] == OP_MATCH then
					if bestStart == nil or t[2] == bestStart then
						bestStart = t[2]
						bestEnd = sp
						bestSaves = t[3]
					end
					break
				end
			end

			if sp > runeCount then
				break
			end
			if clen == 0 then
				if bestStart ~= nil then
					break
				end
				-- Skip ahead to next prefix position
				if nextPrefixPos == nil or nextPrefixPos > scanEnd then
					break
				end
				sp = nextPrefixPos
				continue
			end

			-- Advance consuming instructions
			local rune = runes[sp]
			gen += 1
			nlen = 0

			for i = 1, clen do
				local t = clist[i]
				local pc = t[1]
				local op = code[pc]

				if op == OP_CHAR then
					if rune == code[pc + 1] then
						nlen = addThread(nlist, nlen, pc + 2, t[2], t[3], sp + 1)
					end
				elseif op == OP_CLASS then
					if classes[code[pc + 1]]:contains(rune) then
						nlen = addThread(nlist, nlen, pc + 2, t[2], t[3], sp + 1)
					end
				elseif op == OP_DOT then
					nlen = addThread(nlist, nlen, pc + 1, t[2], t[3], sp + 1)
				elseif op == OP_CHAR_FOLD then
					if Utf8.foldCanonicalRune(rune, code[pc + 2]) == code[pc + 1] then
						nlen = addThread(nlist, nlen, pc + 3, t[2], t[3], sp + 1)
					end
				end
			end

			clist, nlist = nlist, clist
			clen = nlen
			sp += 1
		end

		if bestStart then
			return bestStart, bestEnd, materializeSaves(bestSaves)
		end
		return nil
	end

	-- Standard path: try starting at every position up to scanEnd
	for sp = startPos, runeCount + 1 do
		-- Add start thread (only if no match yet, and within scan range)
		if bestStart == nil and sp <= scanEnd then
			-- When no existing threads, increment gen so stale visited marks
			-- from the previous start thread's epsilon walk are cleared.
			-- When existing threads are present (from advance step), reuse gen
			-- so their PCs block the start thread (higher priority).
			if clen == 0 then
				gen += 1
			end
			clen = addThread(clist, clen, 1, sp, nil, sp)
		end

		-- Check for MATCH
		for i = 1, clen do
			local t = clist[i]
			if code[t[1]] == OP_MATCH then
				if bestStart == nil or t[2] == bestStart then
					bestStart = t[2]
					bestEnd = sp
					bestSaves = t[3]
				end
				break
			end
		end

		if sp > runeCount then
			break
		end
		if clen == 0 then
			if bestStart ~= nil then
				break
			end
			if sp >= scanEnd then
				break
			end
			continue
		end

		-- Advance consuming instructions
		local rune = runes[sp]
		gen += 1
		nlen = 0

		for i = 1, clen do
			local t = clist[i]
			local pc = t[1]
			local op = code[pc]

			if op == OP_CHAR then
				if rune == code[pc + 1] then
					nlen = addThread(nlist, nlen, pc + 2, t[2], t[3], sp + 1)
				end
			elseif op == OP_CLASS then
				if classes[code[pc + 1]]:contains(rune) then
					nlen = addThread(nlist, nlen, pc + 2, t[2], t[3], sp + 1)
				end
			elseif op == OP_DOT then
				nlen = addThread(nlist, nlen, pc + 1, t[2], t[3], sp + 1)
			elseif op == OP_CHAR_FOLD then
				if Utf8.foldCanonicalRune(rune, code[pc + 2]) == code[pc + 1] then
					nlen = addThread(nlist, nlen, pc + 3, t[2], t[3], sp + 1)
				end
			end
		end

		clist, nlist = nlist, clist
		clen = nlen
	end

	if bestStart then
		return bestStart, bestEnd, materializeSaves(bestSaves)
	end
	return nil
end

return NFA
