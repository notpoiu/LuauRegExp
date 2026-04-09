local Utf8 = require("./regexp/Utf8")
local CharClass = require("./regexp/CharClass")
local NFA = require("./regexp/NFA")

local bit = bit32

local Regexp = {}
local Node = {}
Node.__index = Node

Regexp.NoParseFlags = 0
Regexp.FoldCase = bit.lshift(1, 0)
Regexp.Literal = bit.lshift(1, 1)
Regexp.MatchNL = bit.lshift(1, 2)
Regexp.PerlX = bit.lshift(1, 3)
Regexp.PerlClasses = bit.lshift(1, 4)
Regexp.UnicodeGroups = bit.lshift(1, 5)
Regexp.NeverNL = bit.lshift(1, 6)
Regexp.Latin1 = bit.lshift(1, 7)
Regexp.OneLine = bit.lshift(1, 8)
Regexp.NonGreedy = bit.lshift(1, 9)
Regexp.WasDollar = bit.lshift(1, 10)
Regexp.PCRE2 = bit.lshift(1, 11)
Regexp.LikePerl = bit.bor(Regexp.PerlX, Regexp.PerlClasses, Regexp.UnicodeGroups, Regexp.OneLine)
Regexp.LikePCRE2 = bit.bor(Regexp.LikePerl, Regexp.PCRE2)

Regexp.kRegexpBadNamedCapture = "bad_named_capture"
Regexp.kRegexpBadPerlOp = "bad_perl_op"
Regexp.kRegexpBadUTF8 = "bad_utf8"
Regexp.kRegexpMissingParen = "missing_paren"
Regexp.kRegexpMissingBracket = "missing_bracket"
Regexp.kRegexpInvalidRepeat = "invalid_repeat"
Regexp.kRegexpInvalidCharClass = "invalid_char_class"
Regexp.kRegexpInvalidEscape = "invalid_escape"

local Runemax = Utf8.Runemax
local INF = math.huge

local function hasFlag(flags: number, mask: number): boolean
	return bit.band(flags, mask) ~= 0
end

local function newStatus()
	return {
		okValue = true,
		codeValue = nil,
		errorArgValue = "",
		textValue = "",
		ok = function(self)
			return self.okValue
		end,
		code = function(self)
			return self.codeValue
		end,
		error_arg = function(self)
			return self.errorArgValue
		end,
		Text = function(self)
			return self.textValue
		end,
	}
end

Regexp.newStatus = newStatus

local function setStatus(status, code, text, errorArg)
	if status ~= nil then
		status.okValue = false
		status.codeValue = code
		status.textValue = text or tostring(code)
		status.errorArgValue = errorArg or ""
	end
end

local function node(kind: string, fields)
	fields = fields or {}
	fields.kind = kind
	fields.refCount = fields.refCount or 1
	fields.repeatBudget = fields.repeatBudget or 1
	return setmetatable(fields, Node)
end

local function cloneArray(values)
	local result = {}
	for _, value in ipairs(values) do
		table.insert(result, value)
	end
	return result
end

local function decodeRunes(text: string, latin1: boolean): { number }
	local runes, err = Utf8.decodeAll(text, latin1)
	if runes == nil then
		error(err)
	end
	return runes
end

local function runeString(r: number, latin1: boolean): string
	return Utf8.runeToString(r, latin1)
end

local function isValidRuneValue(r: number, latin1: boolean): boolean
	if r < 0 then
		return false
	end
	if latin1 then
		return r <= 0xFF
	end
	return r <= Runemax and not (r >= 0xD800 and r <= 0xDFFF)
end

local function literalNode(text: string, fold: boolean, latin1: boolean, flags: number, quoted: boolean?)
	if text == "" then
		return node("empty", {
			latin1 = latin1,
			renderFlags = flags,
		})
	end
	return node("literal", {
		text = text,
		fold = fold,
		quoted = quoted == true,
		latin1 = latin1,
		renderFlags = flags,
	})
end

local function emptyNode(latin1: boolean, flags: number)
	return node("empty", {
		latin1 = latin1,
		renderFlags = flags,
	})
end

local function charClassFromRunes(runes)
	local cc = CharClass.new()
	for _, r in ipairs(runes) do
		cc:addChar(r)
	end
	return cc
end

local function isFoldLiteralSet(cc, latin1)
	local candidates = {
		0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D,
		0x6E, 0x6F, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A,
	}
	for _, candidate in ipairs(candidates) do
		local folded = charClassFromRunes(Utf8.foldClosure(candidate, latin1))
		if cc:equals(folded) then
			return candidate
		end
	end
	return nil
end

local function charClassNode(cc, latin1: boolean, flags: number)
	local single = cc:singleRune()
	if single ~= nil then
		return literalNode(runeString(single, latin1), false, latin1, flags)
	end

	return node("charclass", {
		class = cc,
		latin1 = latin1,
		renderFlags = flags,
	})
end

local function dumpLiteralText(text: string): string
	return text
end

local function nodeDump(re): string
	if re.kind == "empty" then
		return "emp{}"
	elseif re.kind == "literal" then
		local runes = decodeRunes(re.text, re.latin1)
		local prefix
		if #runes == 1 then
			prefix = re.fold and "litfold{" or "lit{"
		else
			prefix = re.fold and "strfold{" or "str{"
		end
		return prefix .. dumpLiteralText(re.text) .. "}"
	elseif re.kind == "charclass" then
		return "cc{" .. re.class:dumpBody() .. "}"
	elseif re.kind == "dot" then
		return "dot{}"
	elseif re.kind == "byte" then
		return "byte{}"
	elseif re.kind == "anchor" then
		if re.anchor == "eot" and re.flavor == "\\z" then
			return "eot{\\z}"
		end
		return re.anchor .. "{}"
	elseif re.kind == "boundary" then
		return (re.word and "wb" or "nwb") .. "{}"
	elseif re.kind == "lookaround" then
		if re.direction == "ahead" then
			return (re.positive and "pla{" or "nla{") .. nodeDump(re.child) .. "}"
		end
		return (re.positive and "plb{" or "nlb{") .. nodeDump(re.child) .. "}"
	elseif re.kind == "atomic" then
		return "atomic{" .. nodeDump(re.child) .. "}"
	elseif re.kind == "backref" then
		return "backref{" .. tostring(re.ref) .. "}"
	elseif re.kind == "capture" then
		local label = re.name and ("cap{" .. re.name .. ":") or "cap{"
		return label .. nodeDump(re.child) .. "}"
	elseif re.kind == "concat" then
		local parts = {}
		for _, child in ipairs(re.children) do
			table.insert(parts, nodeDump(child))
		end
		return "cat{" .. table.concat(parts) .. "}"
	elseif re.kind == "alt" then
		local parts = {}
		for _, child in ipairs(re.children) do
			table.insert(parts, nodeDump(child))
		end
		return "alt{" .. table.concat(parts) .. "}"
	elseif re.kind == "repeat" then
		local prefix
		if re.possessive then
			if re.min == 0 and re.max == INF then
				prefix = "pstar{"
			elseif re.min == 1 and re.max == INF then
				prefix = "pplus{"
			elseif re.min == 0 and re.max == 1 then
				prefix = "pque{"
			else
				local max = re.max == INF and -1 or re.max
				prefix = string.format("prep{%d,%d ", re.min, max)
			end
		elseif re.min == 0 and re.max == INF then
			prefix = re.nongreedy and "nstar{" or "star{"
		elseif re.min == 1 and re.max == INF then
			prefix = re.nongreedy and "nplus{" or "plus{"
		elseif re.min == 0 and re.max == 1 then
			prefix = re.nongreedy and "nque{" or "que{"
		else
			local name = re.nongreedy and "nrep{" or "rep{"
			local max = re.max == INF and -1 or re.max
			prefix = string.format("%s%d,%d ", name, re.min, max)
		end
		return prefix .. nodeDump(re.child) .. "}"
	elseif re.kind == "raw" then
		return re.rawDump or ("raw{" .. re.rawString .. "}")
	end
	error("unknown dump node kind: " .. tostring(re.kind))
end

local function precedenceOf(re): number
	if re.kind == "alt" then
		return 1
	elseif re.kind == "concat" then
		return 2
	elseif re.kind == "repeat" then
		return 3
	end
	return 4
end

local function runeClassString(r: number): string
	return "[" .. CharClass.new():addClass(charClassFromRunes(Utf8.foldClosure(r, false))):classBody() .. "]"
end

local function renderLiteral(re): string
	local runes = decodeRunes(re.text, re.latin1)
	local parts = {}
	for _, rune in ipairs(runes) do
		if re.fold then
			local cc = charClassFromRunes(Utf8.foldClosure(rune, re.latin1))
			table.insert(parts, "[" .. cc:classBody() .. "]")
		else
			table.insert(parts, Utf8.escapeLiteralRune(rune, re.latin1))
		end
	end
	return table.concat(parts)
end

local function renderNode(re, flags: number, parentPrec: number?, inAltBranch: boolean?): string
	parentPrec = parentPrec or 0
	local text

	if re.kind == "empty" then
		text = inAltBranch and "(?:)" or ""
	elseif re.kind == "literal" then
		text = renderLiteral(re)
	elseif re.kind == "charclass" then
		if re.renderOptions ~= nil then
			text = "(?:" .. table.concat(re.renderOptions, "|") .. ")"
		else
			text = re.class:toRegex(flags)
		end
	elseif re.kind == "dot" then
		text = "."
	elseif re.kind == "byte" then
		text = "\\C"
	elseif re.kind == "anchor" then
		if re.anchor == "bol" then
			text = "(?m:^)"
		elseif re.anchor == "eol" then
			text = "(?m:$)"
		elseif re.anchor == "bot" then
			text = "\\A"
		elseif re.anchor == "eot" then
			text = "\\z"
		end
	elseif re.kind == "boundary" then
		text = re.word and "\\b" or "\\B"
	elseif re.kind == "lookaround" then
		local inner = renderNode(re.child, flags, 0, false)
		if re.direction == "ahead" then
			text = (re.positive and "(?=" or "(?!") .. inner .. ")"
		else
			text = (re.positive and "(?<=" or "(?<!") .. inner .. ")"
		end
	elseif re.kind == "atomic" then
		text = "(?>" .. renderNode(re.child, flags, 0, false) .. ")"
	elseif re.kind == "backref" then
		if re.named then
			if re.syntax == "pcre" then
				text = "(?P=" .. tostring(re.ref) .. ")"
			elseif re.syntax == "quote" then
				text = "\\k'" .. tostring(re.ref) .. "'"
			elseif re.syntax == "brace" then
				text = "\\k{" .. tostring(re.ref) .. "}"
			else
				text = "\\k<" .. tostring(re.ref) .. ">"
			end
		else
			text = "\\" .. tostring(re.ref)
		end
	elseif re.kind == "capture" then
		local inner = renderNode(re.child, flags, 0, false)
		if re.name ~= nil then
			text = "(?P<" .. re.name .. ">" .. inner .. ")"
		else
			text = "(" .. inner .. ")"
		end
	elseif re.kind == "concat" then
		local parts = {}
		for _, child in ipairs(re.children) do
			local childText = renderNode(child, flags, precedenceOf(re), false)
			table.insert(parts, childText)
		end
		text = table.concat(parts)
		if re.preserve and parentPrec >= precedenceOf(re) then
			text = "(?:" .. text .. ")"
		end
	elseif re.kind == "alt" then
		local parts = {}
		for _, child in ipairs(re.children) do
			table.insert(parts, renderNode(child, flags, precedenceOf(re), true))
		end
		text = table.concat(parts, "|")
	elseif re.kind == "repeat" then
		local child = re.child
		local childText = renderNode(child, flags, precedenceOf(re), false)
		if child.kind == "alt" or child.kind == "concat" or child.kind == "empty" then
			childText = "(?:" .. renderNode(child, flags, 0, true) .. ")"
		elseif child.kind == "literal" then
			local runes = decodeRunes(child.text, child.latin1)
			if #runes > 1 then
				childText = "(?:" .. renderNode(child, flags, 0, false) .. ")"
			end
		elseif child.kind == "repeat" then
			childText = "(?:" .. renderNode(child, flags, 0, true) .. ")"
		end

		local suffix
		if re.min == 0 and re.max == INF then
			suffix = "*"
		elseif re.min == 1 and re.max == INF then
			suffix = "+"
		elseif re.min == 0 and re.max == 1 then
			suffix = "?"
		elseif re.min == re.max then
			suffix = "{" .. tostring(re.min) .. "}"
		elseif re.max == INF then
			suffix = "{" .. tostring(re.min) .. ",}"
			else
				suffix = "{" .. tostring(re.min) .. "," .. tostring(re.max) .. "}"
			end
			if re.possessive then
				suffix ..= "+"
			elseif re.nongreedy then
				suffix ..= "?"
			end
			text = childText .. suffix
	elseif re.kind == "raw" then
		text = re.rawString
	else
		error("unknown render node kind: " .. tostring(re.kind))
	end

	if precedenceOf(re) < parentPrec and text ~= "" then
		return "(?:" .. text .. ")"
	end
	return text
end

function Node:Dump(): string
	return nodeDump(self)
end

function Node:ToString(): string
	if self.source ~= nil then
		return self.source
	end
	return renderNode(self, self.renderFlags or 0, 0, false)
end

function Node:Incref()
	self.refCount += 1
	return self
end

function Node:Decref()
	self.refCount = math.max(0, self.refCount - 1)
	return self.refCount
end

function Node:Ref()
	return self.refCount
end

local function collectCaptureMaps(re, named, byIndex)
	if re.kind == "capture" then
		if re.name ~= nil then
			if named[re.name] == nil then
				named[re.name] = re.index
			end
			byIndex[re.index] = re.name
		end
		collectCaptureMaps(re.child, named, byIndex)
	elseif re.kind == "lookaround" or re.kind == "atomic" then
		collectCaptureMaps(re.child, named, byIndex)
	elseif re.kind == "concat" or re.kind == "alt" then
		for _, child in ipairs(re.children) do
			collectCaptureMaps(child, named, byIndex)
		end
	elseif re.kind == "repeat" then
		collectCaptureMaps(re.child, named, byIndex)
	end
end

function Node:NumCaptures()
	return self.numCaptures or 0
end

function Node:NamedCaptures()
	local named = {}
	local byIndex = {}
	collectCaptureMaps(self, named, byIndex)
	return named
end

function Node:CaptureNames()
	local named = {}
	local byIndex = {}
	collectCaptureMaps(self, named, byIndex)
	return byIndex
end

local function sameDump(a, b): boolean
	return nodeDump(a) == nodeDump(b)
end

local function splitLiteralToAtoms(re)
	if re.kind ~= "literal" then
		return { re }
	end
	local runes = decodeRunes(re.text, re.latin1)
	if #runes <= 1 then
		return { re }
	end
	local atoms = {}
	for _, rune in ipairs(runes) do
		local shouldFold = re.fold and #Utf8.foldClosure(rune, re.latin1) > 1
		local canonical = shouldFold and Utf8.foldCanonicalRune(rune, re.latin1) or rune
		table.insert(atoms, literalNode(runeString(canonical, re.latin1), shouldFold, re.latin1, re.renderFlags))
	end
	return atoms
end

local function sequenceFromNode(re)
	if re.kind == "empty" then
		return {}
	elseif re.kind == "concat" then
		local sequence = {}
		for _, child in ipairs(re.children) do
			for _, atom in ipairs(sequenceFromNode(child)) do
				table.insert(sequence, atom)
			end
		end
		return sequence
	else
		return splitLiteralToAtoms(re)
	end
end

local function concatNodes(children, latin1, flags)
	local flat = {}
	for _, child in ipairs(children) do
		if child.kind == "empty" then
			continue
		end
		if child.kind == "concat" and not child.preserve then
			for _, grandchild in ipairs(child.children) do
				table.insert(flat, grandchild)
			end
		else
			table.insert(flat, child)
		end
	end

	if #flat == 0 then
		return emptyNode(latin1, flags)
	end

	local merged = {}
	local pendingText = nil
	local pendingFold = false
	local pendingLatin1 = latin1

	local function flushPending()
		if pendingText ~= nil then
			table.insert(merged, literalNode(table.concat(pendingText), pendingFold, pendingLatin1, flags))
			pendingText = nil
		end
	end

	for _, child in ipairs(flat) do
		if child.kind == "literal" then
			if pendingText ~= nil and pendingLatin1 == child.latin1 and (pendingFold == child.fold or hasFlag(flags, Regexp.FoldCase)) then
				table.insert(pendingText, child.text)
				pendingFold = pendingFold or child.fold or hasFlag(flags, Regexp.FoldCase)
			else
				flushPending()
				pendingText = { child.text }
				pendingFold = child.fold
				pendingLatin1 = child.latin1
			end
		else
			flushPending()
			table.insert(merged, child)
		end
	end
	flushPending()

	if #merged == 1 then
		return merged[1]
	end
	return node("concat", {
		children = merged,
		latin1 = latin1,
		renderFlags = flags,
		repeatBudget = (function()
			local total = 0
			for _, child in ipairs(merged) do
				total += child.repeatBudget or 1
			end
			return total
		end)(),
	})
end

local function classForSingleAtom(re, flags)
	if re.kind == "literal" then
		local runes = decodeRunes(re.text, re.latin1)
		if #runes ~= 1 then
			return nil
		end
		if re.fold then
			return charClassFromRunes(Utf8.foldClosure(runes[1], re.latin1))
		end
		return charClassFromRunes(runes)
	elseif re.kind == "charclass" then
		return re.class:copy()
	elseif re.kind == "dot" then
		if hasFlag(flags, Regexp.MatchNL) and not hasFlag(flags, Regexp.NeverNL) then
			local cc = CharClass.new()
			cc:addRange(0, Runemax)
			return cc
		end
	end
	return nil
end

local function hasPCRE2(flags: number): boolean
	return hasFlag(flags, Regexp.PCRE2)
end

local function mergeSingleAtomAlternation(children, latin1, flags)
	if #children < 2 then
		return nil
	end

	local sawDot = false

	local union = CharClass.new()
	for _, child in ipairs(children) do
		if child.kind == "dot" then
			sawDot = true
		end
		local cc = classForSingleAtom(child, flags)
		if cc == nil then
			return nil
		end
		union:addClass(cc)
	end

	if sawDot and union:isFull() then
		return node("dot", {
			latin1 = latin1,
			renderFlags = flags,
		})
	end

	local folded = isFoldLiteralSet(union, latin1)
	if folded ~= nil then
		local options = {}
		for _, rune in ipairs(Utf8.foldClosure(folded, latin1)) do
			table.insert(options, Utf8.escapeLiteralRune(rune, latin1))
		end
		return node("charclass", {
			class = union,
			latin1 = latin1,
			renderFlags = flags,
			renderOptions = options,
		})
	end

	return charClassNode(union, latin1, flags)
end

local function mergeAltRuns(children, latin1, flags)
	local merged = {}
	local run = {}

	local function flush()
		if #run > 1 then
			table.insert(merged, mergeSingleAtomAlternation(run, latin1, flags))
		elseif #run == 1 then
			table.insert(merged, run[1])
		end
		run = {}
	end

	for _, child in ipairs(children) do
		if classForSingleAtom(child, flags) ~= nil and child.kind ~= "dot" then
			table.insert(run, child)
		else
			flush()
			table.insert(merged, child)
		end
	end
	flush()

	return merged
end

local function sequenceKey(sequence)
	if #sequence == 0 then
		return "__empty__"
	end
	return nodeDump(sequence[1])
end

local normalizeAlt
local isEmptyWidth

local function nodeFromSequence(sequence, latin1, flags)
	return concatNodes(sequence, latin1, flags)
end

local function factorAlternation(children, latin1, flags)
	local merged = mergeSingleAtomAlternation(children, latin1, flags)
	if merged ~= nil then
		return merged
	end

	local sequences = {}
	for _, child in ipairs(children) do
		table.insert(sequences, sequenceFromNode(child))
	end

	local groups = {}
	for _, sequence in ipairs(sequences) do
		local key = sequenceKey(sequence)
		local last = groups[#groups]
		if last == nil or last.key ~= key then
			last = { key = key, first = sequence[1], remainders = {} }
			table.insert(groups, last)
		end
		local remainder = {}
		for index = 2, #sequence do
			table.insert(remainder, sequence[index])
		end
		table.insert(last.remainders, remainder)
	end

	local hasFactor = false
	for _, group in ipairs(groups) do
		if group.key ~= "__empty__" and #group.remainders > 1 then
			hasFactor = true
			break
		end
	end

	if not hasFactor then
		children = mergeAltRuns(children, latin1, flags)
		if #children == 1 then
			return children[1]
		end
		return node("alt", {
			children = children,
			latin1 = latin1,
			renderFlags = flags,
			repeatBudget = (function()
				local maxBudget = 1
				for _, child in ipairs(children) do
					maxBudget = math.max(maxBudget, child.repeatBudget or 1)
				end
				return maxBudget
			end)(),
		})
	end

	local factored = {}
	for _, group in ipairs(groups) do
		if group.key == "__empty__" then
			table.insert(factored, emptyNode(latin1, flags))
		elseif #group.remainders == 1 or group.first.kind == "capture" or (group.first.kind == "repeat" and group.first.min ~= group.first.max) then
			local branch = { group.first }
			for _, tail in ipairs(group.remainders[1]) do
				table.insert(branch, tail)
			end
			table.insert(factored, nodeFromSequence(branch, latin1, flags))
			for remainderIndex = 2, #group.remainders do
				local extra = { group.first }
				for _, tail in ipairs(group.remainders[remainderIndex]) do
					table.insert(extra, tail)
				end
				table.insert(factored, nodeFromSequence(extra, latin1, flags))
			end
		else
			local remainderNodes = {}
			for _, remainder in ipairs(group.remainders) do
				table.insert(remainderNodes, nodeFromSequence(remainder, latin1, flags))
			end
			local suffix = normalizeAlt(remainderNodes, latin1, flags)
			if group.first.kind == "anchor" and suffix.kind == "concat" then
				suffix.preserve = true
			end
			local combined = concatNodes({ group.first, suffix }, latin1, flags)
			table.insert(factored, combined)
		end
	end

	factored = mergeAltRuns(factored, latin1, flags)
	if #factored == 1 then
		return factored[1]
	end

	return node("alt", {
		children = factored,
		latin1 = latin1,
		renderFlags = flags,
		repeatBudget = (function()
			local maxBudget = 1
			for _, child in ipairs(factored) do
				maxBudget = math.max(maxBudget, child.repeatBudget or 1)
			end
			return maxBudget
		end)(),
	})
end

normalizeAlt = function(children, latin1, flags)
	local flat = {}
	for _, child in ipairs(children) do
		if child.kind == "alt" then
			for _, grandchild in ipairs(child.children) do
				table.insert(flat, grandchild)
			end
		else
			table.insert(flat, child)
		end
	end

	if #flat == 0 then
		return emptyNode(latin1, flags)
	end
	if #flat == 1 then
		return flat[1]
	end
	return factorAlternation(flat, latin1, flags)
end

local function makeRepeat(child, min, max, nongreedy, possessive, latin1, flags, keepExactOne, counted)
	local childBudget = child.repeatBudget or 1
	local multiplier = max == INF and math.max(min, 1) or max
	local repeatBudget = childBudget * multiplier
	if repeatBudget > 1000 and not isEmptyWidth(child) then
		return nil, repeatBudget
	end

	if child.kind == "repeat" and child.child ~= nil then
		local inner = child
		local preserveCountedPlus = inner.counted and inner.min == 1 and inner.max == INF and (min == 0 and (max == INF or max == 1))
		if preserveCountedPlus then
			return node("repeat", {
				child = child,
				min = min,
				max = max,
				nongreedy = nongreedy,
				possessive = possessive,
				latin1 = latin1,
				renderFlags = flags,
				counted = counted,
				repeatBudget = repeatBudget,
			})
		end
		if inner.min == 0 and inner.max == INF then
			return node("repeat", {
				child = inner.child,
				min = 0,
				max = INF,
				nongreedy = nongreedy,
				possessive = possessive,
				latin1 = latin1,
				renderFlags = flags,
				repeatBudget = repeatBudget,
			})
		elseif inner.min == 1 and inner.max == INF then
			if min == 1 and max == INF then
				return node("repeat", {
					child = inner.child,
					min = 1,
					max = INF,
					nongreedy = nongreedy,
					possessive = possessive,
					latin1 = latin1,
					renderFlags = flags,
					repeatBudget = repeatBudget,
				})
			elseif min == 0 and (max == 1 or max == INF) then
				return node("repeat", {
					child = inner.child,
					min = 0,
					max = INF,
					nongreedy = nongreedy,
					possessive = possessive,
					latin1 = latin1,
					renderFlags = flags,
					repeatBudget = repeatBudget,
				})
			end
		elseif inner.min == 0 and inner.max == 1 then
			if min == 0 and max == 1 then
				return node("repeat", {
					child = inner.child,
					min = 0,
					max = 1,
					nongreedy = nongreedy,
					possessive = possessive,
					latin1 = latin1,
					renderFlags = flags,
					repeatBudget = repeatBudget,
				})
			elseif min == 0 or max == INF then
				return node("repeat", {
					child = inner.child,
					min = 0,
					max = INF,
					nongreedy = nongreedy,
					possessive = possessive,
					latin1 = latin1,
					renderFlags = flags,
					repeatBudget = repeatBudget,
				})
			end
		end
	end

	if min == 1 and max == 1 and not keepExactOne then
		return child, repeatBudget
	end

	return node("repeat", {
		child = child,
		min = min,
		max = max,
		nongreedy = nongreedy,
		possessive = possessive,
		latin1 = latin1,
		renderFlags = flags,
		counted = counted,
		repeatBudget = repeatBudget,
	}), repeatBudget
end

local function escapeNameChar(ch)
	return ch ~= " " and ch ~= ">" and ch ~= ""
end

local Parser = {}
Parser.__index = Parser

function Parser.new(pattern: string, flags: number, status)
	return setmetatable({
		pattern = pattern,
		flags = flags,
		status = status,
		pos = 1,
		latin1 = hasFlag(flags, Regexp.Latin1),
		currentFold = hasFlag(flags, Regexp.FoldCase),
		currentOneLine = hasFlag(flags, Regexp.OneLine),
		currentNonGreedy = hasFlag(flags, Regexp.NonGreedy),
		captureIndex = 0,
		failed = false,
	}, Parser)
end

function Parser:fail(code, text, arg)
	self.failed = true
	setStatus(self.status, code, text, arg)
	return nil
end

function Parser:peekByte(offset)
	offset = offset or 0
	return string.sub(self.pattern, self.pos + offset, self.pos + offset)
end

function Parser:consumeByte(expected)
	if expected ~= nil and self:peekByte() ~= expected then
		return false
	end
	self.pos += 1
	return true
end

function Parser:atEnd(): boolean
	return self.pos > #self.pattern
end

function Parser:readRune()
	local rune, nextPos, err = Utf8.readRune(self.pattern, self.pos, self.latin1)
	if rune == nil or nextPos == nil then
		self:fail(Regexp.kRegexpBadUTF8, "invalid utf-8", "")
		return nil
	end
	self.pos = nextPos
	return rune
end

function Parser:literalRuneNode(rune, fold)
	local canonical = Utf8.foldCanonicalRune(rune, self.latin1)
	local shouldFold = fold and #Utf8.foldClosure(rune, self.latin1) > 1
	return literalNode(runeString(shouldFold and canonical or rune, self.latin1), shouldFold, self.latin1, self.flags)
end

function Parser:parse()
	if not self.latin1 and not Utf8.isValidUtf8(self.pattern) then
		return self:fail(Regexp.kRegexpBadUTF8, "invalid utf-8", "")
	end

	if hasFlag(self.flags, Regexp.Literal) then
		local re = literalNode(self.pattern, hasFlag(self.flags, Regexp.FoldCase), self.latin1, self.flags)
		re.source = self.pattern
		re.numCaptures = self.captureIndex
		return re
	end

	local re = self:parseAlt()
	if self.failed then
		return nil
	end
	if not self:atEnd() then
		return self:fail(Regexp.kRegexpMissingParen, "parse did not consume all input", self:peekByte())
	end
	re.source = self.pattern
	re.numCaptures = self.captureIndex
	return re
end

function Parser:parseAlt(stopAtParen)
	local branches = {}
	while true do
		table.insert(branches, self:parseConcat(stopAtParen))
		if self.failed then
			return nil
		end
		if self:peekByte() ~= "|" then
			break
		end
		self:consumeByte("|")
	end
	return normalizeAlt(branches, self.latin1, self.flags)
end

function Parser:parseConcat(stopAtParen)
	local items = {}
	while not self:atEnd() do
		local ch = self:peekByte()
		if ch == "|" or (stopAtParen and ch == ")") then
			break
		end
		local atom = self:parseRepeat()
		if self.failed or atom == nil then
			return nil
		end
		table.insert(items, atom)
	end
	return concatNodes(items, self.latin1, self.flags)
end

function Parser:parseRepeat()
	local atom = self:parseAtom()
	if self.failed or atom == nil then
		return atom
	end

	while true do
		local start = self.pos
		local ch = self:peekByte()
		local min, max, consumed = nil, nil, false
		local keepExactOne = false
		local counted = false
		local possessive = false

		if ch == "*" then
			min, max, consumed = 0, INF, true
			self:consumeByte("*")
		elseif ch == "+" then
			min, max, consumed = 1, INF, true
			self:consumeByte("+")
		elseif ch == "?" then
			min, max, consumed = 0, 1, true
			self:consumeByte("?")
		elseif ch == "{" then
			local saved = self.pos
			local m, n = string.match(string.sub(self.pattern, self.pos), "^%{(%d+),(%d*)%}")
			if m ~= nil then
				local matched = string.match(string.sub(self.pattern, self.pos), "^%{[%d,]+%}")
				self.pos += #matched
				min = tonumber(m)
				if n == "" then
					max = INF
				else
					max = tonumber(n)
				end
				consumed = true
				counted = true
			else
				local exact = string.match(string.sub(self.pattern, self.pos), "^%{(%d+)%}")
				if exact ~= nil then
					local matched = string.match(string.sub(self.pattern, self.pos), "^%{%d+%}")
					self.pos += #matched
					min = tonumber(exact)
					max = min
					consumed = true
					keepExactOne = true
					counted = true
				else
					self.pos = saved
				end
			end
		end

		if not consumed then
			break
		end

		if min ~= nil and (min > 1000 or (max ~= INF and max > 1000) or (max ~= INF and min > max)) then
			return self:fail(Regexp.kRegexpInvalidRepeat, "invalid repeat", string.sub(self.pattern, start, self.pos - 1))
		end

		local nongreedy = self.currentNonGreedy
		if hasPCRE2(self.flags) and self:peekByte() == "+" then
			possessive = true
			self:consumeByte("+")
		elseif hasFlag(self.flags, Regexp.PerlX) and self:peekByte() == "?" then
			nongreedy = not nongreedy
			self:consumeByte("?")
		elseif hasFlag(self.flags, Regexp.PerlX) and (self:peekByte() == "*" or self:peekByte() == "+" or self:peekByte() == "?") then
			return self:fail(Regexp.kRegexpInvalidRepeat, "duplicate repeat", self:peekByte())
		end

		if atom.kind == "literal" and atom.quoted then
			local runes = decodeRunes(atom.text, atom.latin1)
			if #runes > 1 then
				local prefixRunes = {}
				for index = 1, #runes - 1 do
					table.insert(prefixRunes, runeString(runes[index], atom.latin1))
				end
				local lastRune = runeString(runes[#runes], atom.latin1)
				local prefix = literalNode(table.concat(prefixRunes), atom.fold, atom.latin1, atom.renderFlags)
				local last = literalNode(lastRune, atom.fold, atom.latin1, atom.renderFlags)
				local repeated = select(1, makeRepeat(last, min, max, nongreedy, possessive, self.latin1, self.flags, keepExactOne, counted))
				if repeated == nil then
					return self:fail(Regexp.kRegexpInvalidRepeat, "repeat too large", string.sub(self.pattern, start, self.pos - 1))
				end
				atom = concatNodes({
					prefix,
					repeated,
				}, self.latin1, self.flags)
				continue
			end
		end

		local repeated = select(1, makeRepeat(atom, min, max, nongreedy, possessive, self.latin1, self.flags, keepExactOne, counted))
		if repeated == nil then
			return self:fail(Regexp.kRegexpInvalidRepeat, "repeat too large", string.sub(self.pattern, start, self.pos - 1))
		end
		atom = repeated
	end

	return atom
end

local function isNameValid(name)
	if name == "" then
		return false
	end
	local pos = 1
	while pos <= #name do
		local rune, nextPos = Utf8.readRune(name, pos, false)
		if rune == nil or nextPos == nil then
			return false
		end
		local ch = string.sub(name, pos, nextPos - 1)
		if ch == " " or ch == ">" then
			return false
		end
		pos = nextPos
	end
	return true
end

function Parser:parseGroup()
	self:consumeByte("(")

	if self:peekByte() == "*" and hasPCRE2(self.flags) then
		return self:fail(Regexp.kRegexpBadPerlOp, "unsupported pcre2 verb", "(*")
	end

	if self:peekByte() ~= "?" then
		self.captureIndex += 1
		local capIndex = self.captureIndex
		local child = self:parseAlt(true)
		if child == nil then
			return nil
		end
		if self:peekByte() ~= ")" then
			return self:fail(Regexp.kRegexpMissingParen, "missing )", "(")
		end
		self:consumeByte(")")
		return node("capture", {
			child = child,
			index = capIndex,
			latin1 = self.latin1,
			renderFlags = self.flags,
			repeatBudget = child.repeatBudget or 1,
		})
	end

	if not (hasFlag(self.flags, Regexp.PerlX) or hasPCRE2(self.flags)) then
		return self:fail(Regexp.kRegexpBadPerlOp, "perl extensions disabled", "(?")
	end

	self:consumeByte("?")
	local nextChar = self:peekByte()
	if nextChar == ":" then
		self:consumeByte(":")
		local child = self:parseAlt(true)
		if child ~= nil and child.kind == "concat" and child.children[#child.children] and child.children[#child.children].kind == "alt" then
			child.preserve = true
		end
		if self:peekByte() ~= ")" then
			return self:fail(Regexp.kRegexpMissingParen, "missing )", "(?:")
		end
		self:consumeByte(")")
		return child
	elseif nextChar == ">" and hasPCRE2(self.flags) then
		self:consumeByte(">")
		local child = self:parseAlt(true)
		if child == nil then
			return nil
		end
		if self:peekByte() ~= ")" then
			return self:fail(Regexp.kRegexpMissingParen, "missing )", "(?>")
		end
		self:consumeByte(")")
		return node("atomic", {
			child = child,
			latin1 = self.latin1,
			renderFlags = self.flags,
			repeatBudget = child.repeatBudget or 1,
		})
	elseif nextChar == "P" then
		self:consumeByte("P")
		if self:peekByte() == "=" and hasPCRE2(self.flags) then
			self:consumeByte("=")
			local nameStart = self.pos
			while not self:atEnd() and self:peekByte() ~= ")" do
				self:consumeByte()
			end
			local name = string.sub(self.pattern, nameStart, self.pos - 1)
			if not isNameValid(name) or self:peekByte() ~= ")" then
				return self:fail(Regexp.kRegexpBadNamedCapture, "bad named backreference", "(?P=" .. name)
			end
			self:consumeByte(")")
			return node("backref", {
				ref = name,
				named = true,
				syntax = "pcre",
				latin1 = self.latin1,
				renderFlags = self.flags,
			})
		end
		if self:peekByte() ~= "<" then
			return self:fail(Regexp.kRegexpBadNamedCapture, "bad named capture", "(?P")
		end
		self:consumeByte("<")
		local nameStart = self.pos
		while not self:atEnd() and self:peekByte() ~= ">" do
			self:consumeByte()
		end
		local name = string.sub(self.pattern, nameStart, self.pos - 1)
		local errorArg = "(?P<" .. name
		if self:peekByte() == ">" then
			self:consumeByte(">")
			errorArg ..= ">"
		end
		if not isNameValid(name) or string.sub(errorArg, -1) ~= ">" then
			return self:fail(Regexp.kRegexpBadNamedCapture, "bad named capture", errorArg)
		end
		self.captureIndex += 1
		local capIndex = self.captureIndex
		local child = self:parseAlt(true)
		if child == nil then
			return nil
		end
		if self:peekByte() ~= ")" then
			return self:fail(Regexp.kRegexpMissingParen, "missing )", errorArg)
		end
		self:consumeByte(")")
		return node("capture", {
			child = child,
			index = capIndex,
			name = name,
			latin1 = self.latin1,
			renderFlags = self.flags,
			repeatBudget = child.repeatBudget or 1,
		})
	elseif nextChar == "<" then
		local lookahead = string.sub(self.pattern, self.pos, self.pos + 1)
		if (lookahead == "<=" or lookahead == "<!") and hasPCRE2(self.flags) then
			local positive = lookahead == "<="
			self:consumeByte("<")
			self:consumeByte(string.sub(lookahead, 2, 2))
			local child = self:parseAlt(true)
			if child == nil then
				return nil
			end
			if self:peekByte() ~= ")" then
				return self:fail(Regexp.kRegexpMissingParen, "missing )", "(?" .. lookahead)
			end
			self:consumeByte(")")
			return node("lookaround", {
				direction = "behind",
				positive = positive,
				child = child,
				latin1 = self.latin1,
				renderFlags = self.flags,
				repeatBudget = child.repeatBudget or 1,
			})
		elseif lookahead == "<=" or lookahead == "<!" then
			self:consumeByte("<")
			self:consumeByte(string.sub(lookahead, 2, 2))
			return self:fail(Regexp.kRegexpBadPerlOp, "look-around not supported", "(?" .. lookahead)
		end

		self:consumeByte("<")
		local nameStart = self.pos
		while not self:atEnd() and self:peekByte() ~= ">" do
			self:consumeByte()
		end
		local name = string.sub(self.pattern, nameStart, self.pos - 1)
		local errorArg = "(?<" .. name
		if self:peekByte() == ">" then
			self:consumeByte(">")
			errorArg ..= ">"
		end
		if not isNameValid(name) or string.sub(errorArg, -1) ~= ">" then
			return self:fail(Regexp.kRegexpBadNamedCapture, "bad named capture", errorArg)
		end
		self.captureIndex += 1
		local capIndex = self.captureIndex
		local child = self:parseAlt(true)
		if child == nil then
			return nil
		end
		if self:peekByte() ~= ")" then
			return self:fail(Regexp.kRegexpMissingParen, "missing )", errorArg)
		end
		self:consumeByte(")")
		return node("capture", {
			child = child,
			index = capIndex,
			name = name,
			latin1 = self.latin1,
			renderFlags = self.flags,
			repeatBudget = child.repeatBudget or 1,
		})
	elseif nextChar == "=" or nextChar == "!" then
		if hasPCRE2(self.flags) then
			local positive = nextChar == "="
			self:consumeByte(nextChar)
			local child = self:parseAlt(true)
			if child == nil then
				return nil
			end
			if self:peekByte() ~= ")" then
				return self:fail(Regexp.kRegexpMissingParen, "missing )", "(?" .. nextChar)
			end
			self:consumeByte(")")
			return node("lookaround", {
				direction = "ahead",
				positive = positive,
				child = child,
				latin1 = self.latin1,
				renderFlags = self.flags,
				repeatBudget = child.repeatBudget or 1,
			})
		end
		self:consumeByte(nextChar)
		return self:fail(Regexp.kRegexpBadPerlOp, "look-around not supported", "(?" .. nextChar)
	elseif nextChar == "i" or nextChar == "m" or nextChar == "-" then
		local savedFold = self.currentFold
		local savedOneLine = self.currentOneLine
		local negate = false
		if nextChar == "-" then
			negate = true
			self:consumeByte("-")
			nextChar = self:peekByte()
		end
		local flagChar = nextChar
		self:consumeByte(flagChar)
		local enable = not negate
		if flagChar == "i" then
			self.currentFold = enable
		elseif flagChar == "m" then
			self.currentOneLine = not enable
		end

		if self:peekByte() == ")" then
			self:consumeByte(")")
			return emptyNode(self.latin1, self.flags)
		elseif self:peekByte() == ":" then
			self:consumeByte(":")
			local child = self:parseAlt(true)
			if child ~= nil and child.kind == "concat" and child.children[#child.children] and child.children[#child.children].kind == "alt" then
				child.preserve = true
			end
			if self:peekByte() ~= ")" then
				return self:fail(Regexp.kRegexpMissingParen, "missing )", "(?")
			end
			self:consumeByte(")")
			self.currentFold = savedFold
			self.currentOneLine = savedOneLine
			return child
		end
	end

	return self:fail(Regexp.kRegexpBadPerlOp, "unsupported perl op", "(?")
end

local POSIX_CLASSES = {
	alnum = { { 0x30, 0x39 }, { 0x41, 0x5A }, { 0x61, 0x7A } },
	alpha = { { 0x41, 0x5A }, { 0x61, 0x7A } },
	blank = { { 0x09, 0x09 }, { 0x20, 0x20 } },
	cntrl = { { 0x00, 0x1F }, { 0x7F, 0x7F } },
	digit = { { 0x30, 0x39 } },
	graph = { { 0x21, 0x7E } },
	lower = { { 0x61, 0x7A } },
	print = { { 0x20, 0x7E } },
	punct = { { 0x21, 0x2F }, { 0x3A, 0x40 }, { 0x5B, 0x60 }, { 0x7B, 0x7E } },
	space = { { 0x09, 0x0D }, { 0x20, 0x20 } },
	upper = { { 0x41, 0x5A } },
	xdigit = { { 0x30, 0x39 }, { 0x41, 0x46 }, { 0x61, 0x66 } },
}

local function classFromDefinition(definition)
	local cc = CharClass.new()
	for _, pair in ipairs(definition) do
		cc:addRange(pair[1], pair[2])
	end
	return cc
end

local function addFoldedRuneOrRange(cc, lo, hi, latin1)
	for rune = lo, hi do
		for _, folded in ipairs(Utf8.foldClosure(rune, latin1)) do
			cc:addChar(folded)
		end
	end
end

local function perlClass(name, flags)
	local cc = CharClass.new()
	if name == "d" then
		cc:addRange(0x30, 0x39)
	elseif name == "s" then
		cc:addRange(0x09, 0x0A)
		cc:addRange(0x0C, 0x0D)
		cc:addChar(0x20)
	elseif name == "w" then
		cc:addRange(0x30, 0x39)
		cc:addRange(0x41, 0x5A)
		cc:addChar(0x5F)
		cc:addRange(0x61, 0x7A)
		if hasFlag(flags, Regexp.FoldCase) then
			cc:addChar(0x017F)
			cc:addChar(0x212A)
		end
	end
	return cc
end

function Parser:parseHexEscape()
	if self:peekByte() ~= "x" then
		return nil
	end
	self:consumeByte("x")
	if self:peekByte() == "{" then
		self:consumeByte("{")
		local start = self.pos
		while not self:atEnd() and self:peekByte() ~= "}" do
			self:consumeByte()
		end
		local hex = string.sub(self.pattern, start, self.pos - 1)
		if self:peekByte() ~= "}" or hex == "" then
			return nil
		end
		self:consumeByte("}")
		return tonumber(hex, 16)
	end
	local hex = string.sub(self.pattern, self.pos, self.pos + 1)
	if #hex ~= 2 or not string.match(hex, "^[0-9A-Fa-f][0-9A-Fa-f]$") then
		return nil
	end
	self.pos += 2
	return tonumber(hex, 16)
end

local UNSUPPORTED_PCRE2_ESCAPES = {
	G = true,
	H = true,
	K = true,
	N = true,
	R = true,
	V = true,
	X = true,
	Z = true,
	g = true,
	h = true,
	v = true,
}

function Parser:parseEscape(inClass)
	self:consumeByte("\\")
	local escapeStart = self.pos - 1
	if self:atEnd() then
		return self:fail(Regexp.kRegexpInvalidEscape, "dangling escape", "\\")
	end

	local ch = self:peekByte()
	if not inClass and hasPCRE2(self.flags) and string.match(ch, "^[1-9]$") then
		local start = self.pos
		while not self:atEnd() and string.match(self:peekByte(), "^%d$") do
			self:consumeByte()
		end
		local number = tonumber(string.sub(self.pattern, start, self.pos - 1))
		return node("backref", {
			ref = number,
			named = false,
			latin1 = self.latin1,
			renderFlags = self.flags,
		})
	elseif not inClass and hasPCRE2(self.flags) and ch == "k" then
		self:consumeByte("k")
		local opener = self:peekByte()
		local closer
		local syntax = "angle"
		if opener == "<" then
			closer = ">"
		elseif opener == "'" then
			closer = "'"
			syntax = "quote"
		elseif opener == "{" then
			closer = "}"
			syntax = "brace"
		else
			return self:fail(Regexp.kRegexpInvalidEscape, "invalid named backreference", "\\k")
		end
		self:consumeByte(opener)
		local start = self.pos
		while not self:atEnd() and self:peekByte() ~= closer do
			self:consumeByte()
		end
		local name = string.sub(self.pattern, start, self.pos - 1)
		if not isNameValid(name) or self:peekByte() ~= closer then
			return self:fail(Regexp.kRegexpInvalidEscape, "invalid named backreference", "\\k" .. opener .. name)
		end
		self:consumeByte(closer)
		return node("backref", {
			ref = name,
			named = true,
			syntax = syntax,
			latin1 = self.latin1,
			renderFlags = self.flags,
		})
	elseif hasPCRE2(self.flags) and UNSUPPORTED_PCRE2_ESCAPES[ch] then
		return self:fail(Regexp.kRegexpInvalidEscape, "unsupported pcre2 escape", "\\" .. ch)
	elseif ch == "A" then
		self:consumeByte("A")
		return node("anchor", { anchor = "bot", latin1 = self.latin1, renderFlags = self.flags })
	elseif ch == "z" then
		self:consumeByte("z")
		return node("anchor", { anchor = "eot", flavor = "\\z", latin1 = self.latin1, renderFlags = self.flags })
	elseif ch == "b" then
		self:consumeByte("b")
		return node("boundary", { word = true, latin1 = self.latin1, renderFlags = self.flags })
	elseif ch == "B" then
		self:consumeByte("B")
		return node("boundary", { word = false, latin1 = self.latin1, renderFlags = self.flags })
	elseif ch == "C" then
		self:consumeByte("C")
		return node("byte", { latin1 = self.latin1, renderFlags = self.flags })
	elseif ch == "Q" and hasFlag(self.flags, Regexp.PerlX) then
		self:consumeByte("Q")
		local start = self.pos
		local ending = string.find(self.pattern, "\\E", self.pos, true)
		if ending == nil then
			self.pos = #self.pattern + 1
			return literalNode(string.sub(self.pattern, start), self.currentFold, self.latin1, self.flags)
		end
		local text = string.sub(self.pattern, start, ending - 1)
		self.pos = ending + 2
		if text == "" then
			return self:fail(Regexp.kRegexpInvalidEscape, "empty quoted literal", "\\Q\\E")
		end
		return literalNode(text, self.currentFold, self.latin1, self.flags, true)
	elseif ch == "Q" then
		return self:fail(Regexp.kRegexpBadPerlOp, "quoted literals require perl mode", "\\Q")
	elseif hasFlag(self.flags, Regexp.PerlClasses) and string.find("dDsSwW", ch, 1, true) then
		self:consumeByte(ch)
		local positive = perlClass(string.lower(ch), bit.bor(self.flags, self.currentFold and Regexp.FoldCase or 0))
		if string.lower(ch) ~= ch then
			positive = positive:negate()
			if not hasFlag(self.flags, Regexp.MatchNL) or hasFlag(self.flags, Regexp.NeverNL) then
				local exclude = CharClass.new()
				exclude:addChar(0x0A)
				positive = positive
				local filtered = CharClass.new()
				for _, range in ipairs(positive.ranges) do
					filtered:addRange(range.lo, range.hi)
				end
				local result = CharClass.new()
				for _, range in ipairs(filtered.ranges) do
					if range.hi < 0x0A or range.lo > 0x0A then
						result:addRange(range.lo, range.hi)
					else
						if range.lo < 0x0A then
							result:addRange(range.lo, 0x09)
						end
						if range.hi > 0x0A then
							result:addRange(0x0B, range.hi)
						end
					end
				end
				positive = result
			end
		end
		return charClassNode(positive, self.latin1, self.flags)
	elseif ch == "p" or ch == "P" then
		local negate = ch == "P"
		self:consumeByte(ch)
		if not hasFlag(self.flags, Regexp.UnicodeGroups) or self:peekByte() ~= "{" then
			return self:fail(Regexp.kRegexpInvalidEscape, "invalid unicode class", "\\" .. ch)
		end
		self:consumeByte("{")
		local start = self.pos
		while not self:atEnd() and self:peekByte() ~= "}" do
			self:consumeByte()
		end
		local name = string.sub(self.pattern, start, self.pos - 1)
		if self:peekByte() ~= "}" then
			return self:fail(Regexp.kRegexpInvalidEscape, "invalid unicode class", "\\" .. ch .. "{" .. name)
		end
		self:consumeByte("}")
		local baseNegate = false
		if string.sub(name, 1, 1) == "^" then
			baseNegate = true
			name = string.sub(name, 2)
		end
		local cc = CharClass.new()
		if name == "Braille" then
			cc:addRange(0x2800, 0x28FF)
		else
			return self:fail(Regexp.kRegexpInvalidEscape, "unknown unicode class", name)
		end
		if negate ~= baseNegate then
			cc = cc:negate()
		end
		return charClassNode(cc, self.latin1, self.flags)
	end

	local hexValue = self:parseHexEscape()
	if hexValue ~= nil then
		if not isValidRuneValue(hexValue, self.latin1) then
			return self:fail(
				Regexp.kRegexpInvalidEscape,
				"invalid unicode escape",
				string.sub(self.pattern, escapeStart, self.pos - 1)
			)
		end
		return self:literalRuneNode(hexValue, self.currentFold)
	end

	local escapes = {
		e = 0x1B,
		n = 0x0A,
		r = 0x0D,
		t = 0x09,
		f = 0x0C,
		v = 0x0B,
		a = 0x07,
	}
	if escapes[ch] ~= nil then
		self:consumeByte(ch)
		return self:literalRuneNode(escapes[ch], self.currentFold)
	end

	if ch == "c" then
		self:consumeByte("c")
		if self:atEnd() then
			return self:fail(Regexp.kRegexpInvalidEscape, "dangling control escape", "\\c")
		end
		local rune = self:readRune()
		if rune == nil then
			return nil
		end
		return self:literalRuneNode(bit.band(rune, 0x1F), false)
	end

	local rune = self:readRune()
	if rune == nil then
		return nil
	end
	return self:literalRuneNode(rune, false)
end

function Parser:parseClass()
	self:consumeByte("[")
	local negate = false
	if self:peekByte() == "^" then
		negate = true
		self:consumeByte("^")
	end

	local cc = CharClass.new()
	local expectRangeFrom = nil

	while not self:atEnd() and self:peekByte() ~= "]" do
		if self:peekByte() == "[" and string.sub(self.pattern, self.pos, self.pos + 1) == "[:" then
			local close = string.find(self.pattern, ":]", self.pos + 2, true)
			if close ~= nil then
				local name = string.sub(self.pattern, self.pos + 2, close - 1)
				local posixNegate = false
				if string.sub(name, 1, 1) == "^" then
					posixNegate = true
					name = string.sub(name, 2)
				end
				local def = POSIX_CLASSES[name]
				if def == nil then
					return self:fail(Regexp.kRegexpInvalidCharClass, "unknown posix class", name)
				end
				local part = classFromDefinition(def)
			if self.currentFold then
				local folded = CharClass.new()
				for _, range in ipairs(part.ranges) do
					addFoldedRuneOrRange(folded, range.lo, range.hi, self.latin1)
				end
				part = folded
			end
				if posixNegate then
					part = part:negate()
				end
				cc:addClass(part)
				self.pos = close + 2
				expectRangeFrom = nil
				continue
			end
		end

		local partNode
		local partRune
		if self:peekByte() == "\\" then
			local saved = self.pos
			partNode = self:parseEscape(true)
			if self.failed then
				return nil
			end
			if partNode.kind == "literal" then
				local runes = decodeRunes(partNode.text, partNode.latin1)
				partRune = runes[1]
			elseif partNode.kind == "charclass" or partNode.kind == "dot" then
				cc:addClass(classForSingleAtom(partNode, self.flags))
				expectRangeFrom = nil
				continue
			else
				return self:fail(Regexp.kRegexpInvalidCharClass, "invalid class escape", string.sub(self.pattern, saved, self.pos - 1))
			end
		else
			if self:peekByte() == "-" and not hasFlag(self.flags, Regexp.PerlX) and string.sub(self.pattern, self.pos + 1, self.pos + 1) ~= "]" then
				return self:fail(Regexp.kRegexpInvalidCharClass, "ambiguous class range", "-")
			end
			partRune = self:readRune()
			if partRune == nil then
				return nil
			end
		end

		if self:peekByte() == "-" and string.sub(self.pattern, self.pos + 1, self.pos + 1) ~= "]" then
			self:consumeByte("-")
			local endRune
			if self:peekByte() == "\\" then
				local part = self:parseEscape(true)
				if self.failed or part == nil or part.kind ~= "literal" then
					return self:fail(Regexp.kRegexpInvalidCharClass, "invalid range", "-")
				end
				local runes = decodeRunes(part.text, part.latin1)
				endRune = runes[1]
			else
				endRune = self:readRune()
			end
			if endRune == nil or partRune > endRune then
				return self:fail(Regexp.kRegexpInvalidCharClass, "invalid range", "range")
			end
			if partRune == string.byte("-") and not hasFlag(self.flags, Regexp.PerlX) then
				return self:fail(Regexp.kRegexpInvalidCharClass, "ambiguous class range", "-")
			end
			if self.currentFold then
				addFoldedRuneOrRange(cc, partRune, endRune, self.latin1)
			else
				cc:addRange(partRune, endRune)
			end
		else
			if self.currentFold then
				for _, folded in ipairs(Utf8.foldClosure(partRune, self.latin1)) do
					cc:addChar(folded)
				end
			else
				cc:addChar(partRune)
			end
		end
		expectRangeFrom = nil
	end

	if self:peekByte() ~= "]" then
		return self:fail(Regexp.kRegexpMissingBracket, "missing ]", "[")
	end
	self:consumeByte("]")

	if negate then
		cc = cc:negate()
		if not hasFlag(self.flags, Regexp.MatchNL) or hasFlag(self.flags, Regexp.NeverNL) then
			local filtered = CharClass.new()
			for _, range in ipairs(cc.ranges) do
				if range.hi < 0x0A or range.lo > 0x0A then
					filtered:addRange(range.lo, range.hi)
				else
					if range.lo < 0x0A then
						filtered:addRange(range.lo, 0x09)
					end
					if range.hi > 0x0A then
						filtered:addRange(0x0B, range.hi)
					end
				end
			end
			cc = filtered
		end
	end

	local foldedLiteral = isFoldLiteralSet(cc, self.latin1)
	if foldedLiteral ~= nil then
		return literalNode(runeString(Utf8.foldCanonicalRune(foldedLiteral, self.latin1), self.latin1), true, self.latin1, self.flags)
	end

	return charClassNode(cc, self.latin1, self.flags)
end

function Parser:parseAtom()
	local ch = self:peekByte()
	if ch == "" then
		return emptyNode(self.latin1, self.flags)
	elseif ch == "(" then
		return self:parseGroup()
	elseif ch == "[" then
		return self:parseClass()
	elseif ch == "." then
		self:consumeByte(".")
		if hasFlag(self.flags, Regexp.MatchNL) and not hasFlag(self.flags, Regexp.NeverNL) then
			return node("dot", { latin1 = self.latin1, renderFlags = self.flags })
		end
		local cc = CharClass.new()
		cc:addRange(0, 0x09)
		cc:addRange(0x0B, Runemax)
		return charClassNode(cc, self.latin1, self.flags)
	elseif ch == "^" then
		self:consumeByte("^")
		return node("anchor", {
			anchor = self.currentOneLine and "bot" or "bol",
			latin1 = self.latin1,
			renderFlags = self.flags,
		})
	elseif ch == "$" then
		self:consumeByte("$")
		return node("anchor", {
			anchor = self.currentOneLine and "eot" or "eol",
			latin1 = self.latin1,
			renderFlags = self.flags,
		})
	elseif ch == "\\" then
		return self:parseEscape(false)
	elseif ch == ")" then
		return self:fail(Regexp.kRegexpMissingParen, "unexpected )", ")")
	end

	local rune = self:readRune()
	if rune == nil then
		return nil
	end
	return self:literalRuneNode(rune, self.currentFold)
end

local function repeatCountString(baseString, min, max, nongreedy)
	local suffix
	if min == 0 and max == INF then
		suffix = "*"
	elseif min == 1 and max == INF then
		suffix = "+"
	elseif min == 0 and max == 1 then
		suffix = "?"
	elseif min == max then
		suffix = "{" .. tostring(min) .. "}"
	elseif max == INF then
		suffix = "{" .. tostring(min) .. ",}"
	else
		suffix = "{" .. tostring(min) .. "," .. tostring(max) .. "}"
	end
	if nongreedy then
		suffix ..= "?"
	end
	return baseString .. suffix
end

isEmptyWidth = function(re)
	if re.kind == "empty" or re.kind == "anchor" or re.kind == "boundary" or re.kind == "lookaround" then
		return true
	elseif re.kind == "atomic" then
		return isEmptyWidth(re.child)
	elseif re.kind == "concat" or re.kind == "alt" then
		for _, child in ipairs(re.children) do
			if not isEmptyWidth(child) then
				return false
			end
		end
		return true
	end
	return false
end

local function repeatBodyString(base, flags)
	local text = renderNode(base, flags, 3, false)
	if base.kind == "alt" or base.kind == "concat" or base.kind == "empty" then
		return "(?:" .. renderNode(base, flags, 0, true) .. ")"
	end
	return text
end

local function atMostString(baseString, count)
	if count == 0 then
		return ""
	elseif count == 1 then
		return baseString .. "?"
	end
	return "(?:" .. baseString .. atMostString(baseString, count - 1) .. ")?"
end

local simplifyNodeString

local function simplifyRepeatString(base, min, max, nongreedy, flags)
	local rawBaseString = simplifyNodeString(base, flags)

	if isEmptyWidth(base) then
		if max == INF then
			min = min > 0 and 1 or 0
		else
			min = math.min(min, 1)
			max = math.min(max, 1)
		end
	end

	if min == 1 and max == 1 then
		if base.kind == "alt" then
			return "(?:" .. rawBaseString .. ")"
		end
		return rawBaseString
	elseif min == 0 and max == 0 then
		return ""
	end

	local baseString = rawBaseString
	if base.kind == "alt" or base.kind == "concat" or base.kind == "empty" or base.kind == "repeat" then
		baseString = "(?:" .. rawBaseString .. ")"
	end

	if min == 0 and max == INF then
		return repeatCountString(baseString, 0, INF, nongreedy)
	elseif min == 1 and max == INF then
		return repeatCountString(baseString, 1, INF, nongreedy)
	elseif min == 0 and max == 1 then
		return repeatCountString(baseString, 0, 1, nongreedy)
	elseif max == INF then
		return string.rep(baseString, math.max(0, min - 1)) .. repeatCountString(baseString, 1, INF, nongreedy)
	elseif min == max then
		return string.rep(rawBaseString, min)
	end

	return string.rep(rawBaseString, min) .. atMostString(baseString, max - min)
end

local function sameBaseForSimplify(a, b)
	return nodeDump(a) == nodeDump(b)
end

simplifyNodeString = function(re, flags)
	if re.kind == "raw" then
		return re.rawString
	elseif re.kind == "charclass" and re.class:isFull() then
		return "."
	elseif re.kind == "anchor" then
		if re.anchor == "bol" then
			return "^"
		elseif re.anchor == "eol" then
			return "$"
		elseif re.anchor == "bot" then
			return "(?-m:^)"
		end
		return re.flavor == "\\z" and "\\z" or "(?-m:$)"
	elseif re.kind == "literal" or re.kind == "charclass" or re.kind == "dot" or re.kind == "byte" or re.kind == "boundary" or re.kind == "lookaround" or re.kind == "atomic" or re.kind == "backref" then
		return renderNode(re, flags, 0, false)
	elseif re.kind == "empty" then
		return ""
	elseif re.kind == "capture" then
		return "(" .. simplifyNodeString(re.child, flags) .. ")"
	elseif re.kind == "alt" then
		local nonEmpty = {}
		local emptyCount = 0
		for _, child in ipairs(re.children) do
			if child.kind == "empty" then
				emptyCount += 1
			else
				table.insert(nonEmpty, child)
			end
		end
		local parts = {}
		if #nonEmpty > 0 then
			local merged = mergeSingleAtomAlternation(nonEmpty, re.latin1 or false, flags)
			if merged ~= nil then
				table.insert(parts, simplifyNodeString(merged, flags))
			else
				for _, child in ipairs(nonEmpty) do
					table.insert(parts, simplifyNodeString(child, flags))
				end
			end
		end
		for _ = 1, emptyCount do
			table.insert(parts, "(?:)")
		end
		return table.concat(parts, "|")
	elseif re.kind == "repeat" then
		if re.possessive then
			return renderNode(re, flags, 0, false)
		end
		if re.counted and re.child.kind == "repeat" and re.child.counted and re.child.min == 1 and re.child.max == INF then
			return simplifyRepeatString(re.child.child, 0, INF, re.nongreedy, flags)
		end
		return simplifyRepeatString(re.child, re.min, re.max, re.nongreedy, flags)
	elseif re.kind == "concat" then
		local units = {}
		local function addNodeAsUnits(value)
			if value.kind == "concat" then
				for _, child in ipairs(value.children) do
					addNodeAsUnits(child)
				end
				return
			end

			for _, atom in ipairs(splitLiteralToAtoms(value)) do
				if atom.kind == "repeat" then
					table.insert(units, {
						base = atom.child,
						min = atom.min,
						max = atom.max,
						nongreedy = atom.nongreedy,
					})
				else
					table.insert(units, {
						base = atom,
						min = 1,
						max = 1,
						nongreedy = false,
					})
				end
			end
		end

		for _, child in ipairs(re.children) do
			addNodeAsUnits(child)
		end

		local merged = {}
		for _, unit in ipairs(units) do
			local last = merged[#merged]
			local compatibleGreediness = last ~= nil and (last.nongreedy == unit.nongreedy or (last.min == 1 and last.max == 1) or (unit.min == 1 and unit.max == 1))
			if last ~= nil and compatibleGreediness and sameBaseForSimplify(last.base, unit.base) then
				last.min += unit.min
				if last.max == INF or unit.max == INF then
					last.max = INF
				else
					last.max += unit.max
				end
				last.nongreedy = last.nongreedy and unit.nongreedy
			else
				table.insert(merged, {
					base = unit.base,
					min = unit.min,
					max = unit.max,
					nongreedy = unit.nongreedy,
				})
			end
		end

		local parts = {}
		for _, unit in ipairs(merged) do
			table.insert(parts, simplifyRepeatString(unit.base, unit.min, unit.max, unit.nongreedy, flags))
		end
		return table.concat(parts)
	end

	error("unknown simplify node: " .. tostring(re.kind))
end

function Node:Simplify()
	local simplified = simplifyNodeString(self, self.renderFlags or 0)
	if simplified == (self.source or self:ToString()) then
		return self
	end
	return node("raw", {
		rawString = simplified,
		rawDump = self:Dump(),
		renderFlags = self.renderFlags,
		latin1 = self.latin1,
		numCaptures = self.numCaptures,
		source = simplified,
	})
end

function Regexp.Equal(a, b): boolean
	return sameDump(a, b)
end

local function cloneCaptures(captures)
	if captures == nil then
		return {}
	end

	local copy = {}
	for index, capture in pairs(captures) do
		copy[index] = {
			startPos = capture.startPos,
			endPos = capture.endPos,
		}
	end
	return copy
end

local function literalMatchRunes(re)
	if re._matchRunes == nil then
		re._matchRunes = decodeRunes(re.text, re.latin1)
	end
	return re._matchRunes
end

local function isAsciiString(text: string): boolean
	return string.find(text, "[\128-\255]") == nil
end

local function prepareSubject(text: string, latin1: boolean)
	local len = #text

	-- Fast path: for ASCII-only text (common in source code), byte == rune
	if latin1 or isAsciiString(text) then
		local runes = table.create(len)
		for i = 1, len do
			runes[i] = string.byte(text, i)
		end
		return {
			text = text,
			latin1 = latin1,
			runes = runes,
			bytePositions = nil, -- identity mapping: bytePositions[i] == i for ASCII
			runeCount = len,
			isAscii = true,
		}
	end

	local runes = {}
	local bytePositions = {}
	local pos = 1
	local index = 1

	while pos <= len do
		bytePositions[index] = pos
		local rune, nextPos, err = Utf8.readRune(text, pos, latin1)
		if rune == nil or nextPos == nil then
			return nil, err or "invalid utf-8"
		end
		runes[index] = rune
		pos = nextPos
		index += 1
	end

	bytePositions[index] = len + 1

	return {
		text = text,
		latin1 = latin1,
		runes = runes,
		bytePositions = bytePositions,
		runeCount = index - 1,
		isAscii = false,
	}
end

local function runePosToByte(subject, runePos: number): number
	if subject.isAscii then
		return runePos
	end
	return subject.bytePositions[runePos]
end

local function byteIndexToRunePosition(subject, byteIndex: number?): number
	if byteIndex == nil or byteIndex <= 1 then
		return 1
	end
	if byteIndex > #subject.text then
		return subject.runeCount + 1
	end
	if subject.isAscii then
		return byteIndex
	end

	local lo = 1
	local hi = subject.runeCount + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if subject.bytePositions[mid] < byteIndex then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

local function isWordRune(rune: number?, latin1: boolean): boolean
	if rune == nil then
		return false
	end
	if rune >= 0x30 and rune <= 0x39 then
		return true
	end
	if rune >= 0x41 and rune <= 0x5A then
		return true
	end
	if rune == 0x5F then
		return true
	end
	if rune >= 0x61 and rune <= 0x7A then
		return true
	end
	if not latin1 and (rune == 0x017F or rune == 0x212A) then
		return true
	end
	return false
end

local function atStartOfLine(subject, pos: number): boolean
	return pos == 1 or subject.runes[pos - 1] == 0x0A
end

local function atEndOfLine(subject, pos: number): boolean
	return pos > subject.runeCount or subject.runes[pos] == 0x0A
end

local function atEndOfText(subject, pos: number, flavor): boolean
	if pos == subject.runeCount + 1 then
		return true
	end
	if flavor == "\\z" then
		return false
	end
	return pos == subject.runeCount and subject.runes[pos] == 0x0A
end

local function ensureNamedCaptures(re)
	if re._namedCaptureCache == nil then
		re._namedCaptureCache = re:NamedCaptures()
	end
	return re._namedCaptureCache
end

local function ensureCaptureNames(re)
	if re._captureNamesCache == nil then
		re._captureNamesCache = re:CaptureNames()
	end
	return re._captureNamesCache
end

local function ensureMatchRoot(re)
	if re.kind ~= "raw" then
		return re, nil
	end
	if re._compiledRaw ~= nil then
		return re._compiledRaw, nil
	end
	if re._compiledRawError ~= nil then
		return nil, re._compiledRawError
	end

	local status = newStatus()
	local compiled = Regexp.Parse(re.rawString, re.renderFlags or 0, status)
	if compiled == nil then
		re._compiledRawError = status:Text()
		return nil, re._compiledRawError
	end

	re._compiledRaw = compiled
	return compiled, nil
end

local function buildMatchResult(re, subject, startPos: number, endPos: number, captures)
	local startByte = runePosToByte(subject, startPos)
	local endByte = runePosToByte(subject, endPos)
	local numCaptures = re:NumCaptures()

	local result = {
		start = startByte,
		finish = endByte,
		text = string.sub(subject.text, startByte, endByte - 1),
	}

	if numCaptures == 0 then
		result.captures = {}
		return result
	end

	local captureNames = ensureCaptureNames(re)
	result.captures = {}
	local named

	for index = 1, numCaptures do
		local capture = captures[index]
		if capture ~= nil then
			local capStart = runePosToByte(subject, capture.startPos)
			local capEnd = runePosToByte(subject, capture.endPos)
			local entry = {
				index = index,
				start = capStart,
				finish = capEnd,
				text = string.sub(subject.text, capStart, capEnd - 1),
			}
			if captureNames[index] ~= nil then
				entry.name = captureNames[index]
				if named == nil then
					named = {}
				end
				if named[entry.name] == nil then
					named[entry.name] = entry
				end
			end
			result.captures[index] = entry
		end
	end

	result.named = named
	return result
end

local matchNode
local matchFirstState

local function isSimpleRepeatChild(re): boolean
	return re.kind == "literal" or re.kind == "charclass" or re.kind == "dot" or re.kind == "byte"
end

local function matchSimpleUnit(re, pos: number, ctx)
	local subject = ctx.subject

	if re.kind == "literal" then
		local runes = literalMatchRunes(re)
		if #runes == 0 or pos + #runes - 1 > subject.runeCount then
			return nil
		end
		for index, rune in ipairs(runes) do
			local candidate = subject.runes[pos + index - 1]
			if re.fold then
				if Utf8.foldCanonicalRune(candidate, re.latin1) ~= Utf8.foldCanonicalRune(rune, re.latin1) then
					return nil
				end
			elseif candidate ~= rune then
				return nil
			end
		end
		return pos + #runes
	elseif re.kind == "charclass" then
		if pos > subject.runeCount or not re.class:contains(subject.runes[pos]) then
			return nil
		end
		return pos + 1
	elseif re.kind == "dot" or re.kind == "byte" then
		if pos > subject.runeCount then
			return nil
		end
		return pos + 1
	end

	return nil
end

local function matchRepeatSimple(re, pos: number, captures, ctx, cont)
	local subject = ctx.subject
	local child = re.child
	local maxCount = re.max == INF and (subject.runeCount + 1) or re.max

	-- Fast path for single-rune-width children (charclass, dot, byte):
	-- each step advances by exactly 1, so positions[i] = pos + i
	local unitWidth = (child.kind == "charclass" or child.kind == "dot" or child.kind == "byte") and 1
		or (child.kind == "literal" and not child.fold and child.text and #child.text == 1) and 1
		or nil

	if unitWidth then
		local currentPos = pos
		local count = 0

		while count < maxCount do
			local nextPos = matchSimpleUnit(child, currentPos, ctx)
			if nextPos == nil then
				break
			end
			count += 1
			currentPos = nextPos
		end

		if count < re.min then
			return nil
		end

		if re.possessive then
			return cont(pos + count, captures)
		end

		if re.nongreedy then
			for acceptedCount = re.min, count do
				local accepted = cont(pos + acceptedCount, captures)
				if accepted ~= nil then
					return accepted
				end
			end
			return nil
		end

		for acceptedCount = count, re.min, -1 do
			local accepted = cont(pos + acceptedCount, captures)
			if accepted ~= nil then
				return accepted
			end
		end

		return nil
	end

	-- General path for multi-rune-width children (multi-char literals)
	local positions = { pos }
	local currentPos = pos
	local count = 0

	while count < maxCount do
		local nextPos = matchSimpleUnit(child, currentPos, ctx)
		if nextPos == nil or nextPos == currentPos then
			break
		end
		count += 1
		currentPos = nextPos
		positions[count + 1] = currentPos
	end

	if count < re.min then
		return nil
	end

	if re.possessive then
		return cont(positions[count + 1], captures)
	end

	if re.nongreedy then
		for acceptedCount = re.min, count do
			local accepted = cont(positions[acceptedCount + 1], captures)
			if accepted ~= nil then
				return accepted
			end
		end
		return nil
	end

	for acceptedCount = count, re.min, -1 do
		local accepted = cont(positions[acceptedCount + 1], captures)
		if accepted ~= nil then
			return accepted
		end
	end

	return nil
end

local function matchLookbehind(child, pos: number, captures, ctx): boolean
	for startPos = pos, 1, -1 do
		local matched = matchFirstState(child, startPos, cloneCaptures(captures), ctx)
		if matched ~= nil and matched.pos == pos then
			return true
		end
	end
	return false
end

local function matchRepeatCore(re, pos: number, captures, ctx, cont)
	local subject = ctx.subject
	local maxCount = re.max == INF and (subject.runeCount + 1) or re.max

	local function step(currentPos: number, currentCaptures, count: number, stalled: boolean)
		local canAccept = count >= re.min

		if re.nongreedy and canAccept then
			local accepted = cont(currentPos, currentCaptures)
			if accepted ~= nil then
				return accepted
			end
		end

		if count < maxCount and not stalled then
			local advanced = matchNode(re.child, currentPos, currentCaptures, ctx, function(nextPos, nextCaptures)
				return step(nextPos, nextCaptures, count + 1, nextPos == currentPos)
			end)
			if advanced ~= nil then
				return advanced
			end
		end

		if not re.nongreedy and canAccept then
			return cont(currentPos, currentCaptures)
		end

		return nil
	end

	return step(pos, captures, 0, false)
end

matchFirstState = function(re, pos: number, captures, ctx)
	return matchNode(re, pos, captures, ctx, function(nextPos, nextCaptures)
		return {
			pos = nextPos,
			captures = nextCaptures,
		}
	end)
end

matchNode = function(re, pos: number, captures, ctx, cont)
	local subject = ctx.subject

	if re.kind == "empty" then
		return cont(pos, captures)
	elseif re.kind == "literal" then
		local runes = literalMatchRunes(re)
		if pos + #runes - 1 > subject.runeCount then
			return nil
		end
		for index, rune in ipairs(runes) do
			local candidate = subject.runes[pos + index - 1]
			if re.fold then
				if Utf8.foldCanonicalRune(candidate, re.latin1) ~= Utf8.foldCanonicalRune(rune, re.latin1) then
					return nil
				end
			elseif candidate ~= rune then
				return nil
			end
		end
		return cont(pos + #runes, captures)
	elseif re.kind == "charclass" then
		if pos > subject.runeCount or not re.class:contains(subject.runes[pos]) then
			return nil
		end
		return cont(pos + 1, captures)
	elseif re.kind == "dot" or re.kind == "byte" then
		if pos > subject.runeCount then
			return nil
		end
		return cont(pos + 1, captures)
	elseif re.kind == "anchor" then
		local matched = false
		if re.anchor == "bot" then
			matched = pos == 1
		elseif re.anchor == "bol" then
			matched = atStartOfLine(subject, pos)
		elseif re.anchor == "eol" then
			matched = atEndOfLine(subject, pos)
		elseif re.anchor == "eot" then
			matched = atEndOfText(subject, pos, re.flavor)
		end
		if not matched then
			return nil
		end
		return cont(pos, captures)
	elseif re.kind == "boundary" then
		local before = isWordRune(subject.runes[pos - 1], re.latin1)
		local after = isWordRune(subject.runes[pos], re.latin1)
		local matched = before ~= after
		if re.word ~= matched then
			return nil
		end
		return cont(pos, captures)
	elseif re.kind == "lookaround" then
		local matched
		if re.direction == "ahead" then
			matched = matchFirstState(re.child, pos, captures, ctx) ~= nil
		else
			matched = matchLookbehind(re.child, pos, captures, ctx)
		end
		if re.positive ~= matched then
			return nil
		end
		return cont(pos, captures)
	elseif re.kind == "atomic" then
		local state = matchFirstState(re.child, pos, captures, ctx)
		if state == nil then
			return nil
		end
		return cont(state.pos, state.captures)
	elseif re.kind == "backref" then
		local captureIndex = re.named and ensureNamedCaptures(ctx.root)[tostring(re.ref)] or re.ref
		local capture = captureIndex ~= nil and captures[captureIndex] or nil
		if capture == nil then
			return nil
		end
		local length = capture.endPos - capture.startPos
		if pos + length - 1 > subject.runeCount then
			return nil
		end
		for offset = 0, length - 1 do
			if subject.runes[capture.startPos + offset] ~= subject.runes[pos + offset] then
				return nil
			end
		end
		return cont(pos + length, captures)
	elseif re.kind == "capture" then
		local startPos = pos
		return matchNode(re.child, pos, captures, ctx, function(nextPos, nextCaptures)
			local updatedCaptures = cloneCaptures(nextCaptures)
			updatedCaptures[re.index] = {
				startPos = startPos,
				endPos = nextPos,
			}
			return cont(nextPos, updatedCaptures)
		end)
	elseif re.kind == "concat" then
		local function matchChild(index: number, currentPos: number, currentCaptures)
			if index > #re.children then
				return cont(currentPos, currentCaptures)
			end
			return matchNode(re.children[index], currentPos, currentCaptures, ctx, function(nextPos, nextCaptures)
				return matchChild(index + 1, nextPos, nextCaptures)
			end)
		end
		return matchChild(1, pos, captures)
	elseif re.kind == "alt" then
		for _, child in ipairs(re.children) do
			local matched = matchNode(child, pos, captures, ctx, cont)
			if matched ~= nil then
				return matched
			end
		end
		return nil
	elseif re.kind == "repeat" then
		if isSimpleRepeatChild(re.child) then
			return matchRepeatSimple(re, pos, captures, ctx, cont)
		end
		if re.possessive then
			local state = matchRepeatCore(re, pos, captures, ctx, function(nextPos, nextCaptures)
				return {
					pos = nextPos,
					captures = nextCaptures,
				}
			end)
			if state == nil then
				return nil
			end
			return cont(state.pos, state.captures)
		end
		return matchRepeatCore(re, pos, captures, ctx, cont)
	elseif re.kind == "raw" then
		local compiled, err = ensureMatchRoot(re)
		if compiled == nil then
			error(err)
		end
		return matchNode(compiled, pos, captures, {
			subject = subject,
			root = compiled,
		}, cont)
	end

	error("unknown match node kind: " .. tostring(re.kind))
end

local function extractLiteralPrefix(re)
	if re._literalPrefix ~= nil then
		return re._literalPrefix
	end

	local prefix = ""
	local current = re

	-- Walk through captures to the inner node
	while current.kind == "capture" do
		current = current.child
	end

	if current.kind == "concat" and current.children and #current.children > 0 then
		-- Walk past leading anchors/boundaries, then collect literal children
		for _, child in ipairs(current.children) do
			local inner = child
			while inner.kind == "capture" do
				inner = inner.child
			end
			if inner.kind == "anchor" or inner.kind == "boundary" or inner.kind == "empty" then
				continue
			end
			if inner.kind == "literal" and not inner.fold and inner.text and #inner.text > 0 then
				prefix = prefix .. inner.text
			else
				break
			end
		end
	elseif current.kind == "literal" and not current.fold and current.text and #current.text > 0 then
		prefix = current.text
	end

	if #prefix == 0 then
		re._literalPrefix = false
	else
		re._literalPrefix = prefix
	end
	return re._literalPrefix
end

local EMPTY_CAPTURES = {}

local reusableCtx = { subject = nil, root = nil }

local function nfaSavesToCaptures(saves, numCaptures)
	if numCaptures == 0 or saves == nil then
		return EMPTY_CAPTURES
	end
	local captures = {}
	for i = 1, numCaptures do
		local s = saves[i * 2 - 1]
		local e = saves[i * 2]
		if s and e then
			captures[i] = { startPos = s, endPos = e }
		end
	end
	return captures
end

local function searchPrepared(re, subject, startPos: number, endPos: number?)
	local root, err = ensureMatchRoot(re)
	if root == nil then
		return nil, err
	end

	-- Try NFA engine first (handles most patterns, much faster)
	local program = NFA.compile(root)
	if program then
		local prefix = extractLiteralPrefix(root)
		local mStart, mEnd, mSaves = NFA.search(program, subject, startPos, endPos, prefix or nil)
		if mStart then
			local captures = nfaSavesToCaptures(mSaves, root:NumCaptures())
			return buildMatchResult(root, subject, mStart, mEnd, captures), nil
		end
		return nil, nil
	end

	-- CPS fallback for backreferences, lookaround, atomic groups
	reusableCtx.subject = subject
	reusableCtx.root = root
	local ctx = reusableCtx

	local scanEnd = endPos or subject.runeCount + 1
	local prefix = extractLiteralPrefix(root)

	if prefix and subject.isAscii then
		local text = subject.text
		local searchFrom = startPos
		while searchFrom <= scanEnd do
			local foundByte = string.find(text, prefix, searchFrom, true)
			if foundByte == nil or foundByte > scanEnd then
				return nil, nil
			end
			local state = matchFirstState(root, foundByte, EMPTY_CAPTURES, ctx)
			if state ~= nil then
				return buildMatchResult(root, subject, foundByte, state.pos, state.captures), nil
			end
			searchFrom = foundByte + 1
		end
		return nil, nil
	end

	for pos = startPos, scanEnd do
		local state = matchFirstState(root, pos, EMPTY_CAPTURES, ctx)
		if state ~= nil then
			return buildMatchResult(root, subject, pos, state.pos, state.captures), nil
		end
	end

	return nil, nil
end

function Node:Search(text: string, startByte: number?)
	local subject, err = prepareSubject(text, self.latin1 or false)
	if subject == nil then
		return nil, err
	end
	return searchPrepared(self, subject, byteIndexToRunePosition(subject, startByte))
end

function Node:FindAll(text: string, maxMatches: number?, startByte: number?)
	local subject, err = prepareSubject(text, self.latin1 or false)
	if subject == nil then
		return nil, err
	end

	local results = {}
	local limit = maxMatches or INF
	local pos = byteIndexToRunePosition(subject, startByte)

	while pos <= subject.runeCount + 1 and #results < limit do
		local match, matchErr = searchPrepared(self, subject, pos)
		if matchErr ~= nil then
			return nil, matchErr
		end
		if match == nil then
			break
		end

		table.insert(results, match)

		local nextPos = byteIndexToRunePosition(subject, match.finish)
		if match.start == match.finish then
			local currentPos = byteIndexToRunePosition(subject, match.start)
			pos = currentPos + 1
		else
			pos = nextPos
		end
	end

	return results, nil
end

function Regexp.PrepareSubject(text: string, latin1: boolean?)
	return prepareSubject(text, latin1 or false)
end

function Node:FindAllPrepared(subject, maxMatches: number?, startPos: number?, endPos: number?)
	local results = {}
	local limit = maxMatches or INF
	local pos = startPos or 1
	local maxPos = endPos or (subject.runeCount + 1)

	while pos <= maxPos and #results < limit do
		local match, matchErr = searchPrepared(self, subject, pos, maxPos)
		if matchErr ~= nil then
			return nil, matchErr
		end
		if match == nil then
			break
		end

		table.insert(results, match)

		local nextPos = byteIndexToRunePosition(subject, match.finish)
		if match.start == match.finish then
			local currentPos = byteIndexToRunePosition(subject, match.start)
			pos = currentPos + 1
		else
			pos = nextPos
		end
	end

	return results, nil
end

function Node:IsMatch(text: string, startByte: number?)
	local match, err = self:Search(text, startByte)
	return match ~= nil, err
end

function Node:FullMatch(text: string)
	local subject, err = prepareSubject(text, self.latin1 or false)
	if subject == nil then
		return false, err
	end

	local root, rootErr = ensureMatchRoot(self)
	if root == nil then
		return false, rootErr
	end

	local matched = matchNode(root, 1, {}, {
		subject = subject,
		root = root,
	}, function(nextPos)
		if nextPos == subject.runeCount + 1 then
			return true
		end
		return nil
	end)

	return matched == true, nil
end

function Regexp.Search(pattern: string, text: string, flags: number?, status, startByte: number?)
	local re = Regexp.Parse(pattern, flags or 0, status)
	if re == nil then
		return nil, status ~= nil and status:Text() or "parse failed"
	end
	return re:Search(text, startByte)
end

function Regexp.FindAll(pattern: string, text: string, flags: number?, status, maxMatches: number?, startByte: number?)
	local re = Regexp.Parse(pattern, flags or 0, status)
	if re == nil then
		return nil, status ~= nil and status:Text() or "parse failed"
	end
	return re:FindAll(text, maxMatches, startByte)
end

function Regexp.IsMatch(pattern: string, text: string, flags: number?, status, startByte: number?)
	local re = Regexp.Parse(pattern, flags or 0, status)
	if re == nil then
		return false, status ~= nil and status:Text() or "parse failed"
	end
	return re:IsMatch(text, startByte)
end

function Regexp.FullMatch(pattern: string, text: string, flags: number?, status)
	local re = Regexp.Parse(pattern, flags or 0, status)
	if re == nil then
		return false, status ~= nil and status:Text() or "parse failed"
	end
	return re:FullMatch(text)
end

function Regexp.Concat(values, n, flags)
	local children = {}
	for index = 1, n do
		table.insert(children, values[index])
	end
	local latin1 = n > 0 and values[1].latin1 or false
	local re = concatNodes(children, latin1, flags or 0)
	re.source = re:ToString()
	re.numCaptures = 0
	return re
end

function Regexp.Parse(pattern: string, flags: number, status)
	status = status or newStatus()
	local parser = Parser.new(pattern, flags or 0, status)
	return parser:parse()
end

return Regexp
