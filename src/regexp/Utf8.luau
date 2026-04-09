local Utf8 = {}

Utf8.Runemax = 0x10FFFF

local function hex(n: number): string
	return string.format("%x", n)
end

function Utf8.isValidUtf8(s: string): boolean
	return utf8.len(s) ~= nil
end

function Utf8.readRune(s: string, pos: number, latin1: boolean): (number?, number?, string?)
	if pos > #s then
		return nil, pos, nil
	end

	local b1 = string.byte(s, pos)
	if b1 == nil then
		return nil, pos, nil
	end

	if latin1 or b1 < 0x80 then
		return b1, pos + 1, nil
	end

	local width
	if b1 < 0xE0 then
		width = 2
	elseif b1 < 0xF0 then
		width = 3
	else
		width = 4
	end

	if pos + width - 1 > #s then
		return nil, pos, "invalid utf-8"
	end

	local ok, value = pcall(utf8.codepoint, s, pos, pos + width - 1)
	if not ok then
		return nil, pos, "invalid utf-8"
	end

	return value, pos + width, nil
end

function Utf8.decodeAll(s: string, latin1: boolean): ({ number }?, string?)
	local result = {}
	local pos = 1
	while pos <= #s do
		local rune, nextPos, err = Utf8.readRune(s, pos, latin1)
		if rune == nil or nextPos == nil then
			return nil, err or "invalid rune"
		end
		table.insert(result, rune)
		pos = nextPos
	end
	return result, nil
end

function Utf8.runeToString(r: number, latin1: boolean): string
	if latin1 then
		return string.char(r)
	end
	return utf8.char(r)
end

function Utf8.foldCanonicalRune(r: number, latin1: boolean): number
	if r >= 0x41 and r <= 0x5A then
		return r + 0x20
	end
	if not latin1 then
		if r == 0x212A then
			return 0x6B
		end
		if r == 0x017F then
			return 0x73
		end
	end
	return r
end

function Utf8.foldClosure(r: number, latin1: boolean): { number }
	local canonical = Utf8.foldCanonicalRune(r, latin1)
	local values = {}
	local seen = {}

	local function add(value: number)
		if not seen[value] then
			seen[value] = true
			table.insert(values, value)
		end
	end

	add(canonical)
	if canonical >= 0x61 and canonical <= 0x7A then
		add(canonical - 0x20)
	end
	if not latin1 then
		if canonical == 0x6B then
			add(0x212A)
		elseif canonical == 0x73 then
			add(0x017F)
		end
	end

	table.sort(values)
	return values
end

function Utf8.dumpRune(r: number): string
	if r == 0 then
		return "0"
	end
	return "0x" .. hex(r)
end

function Utf8.escapeLiteralRune(r: number, latin1: boolean): string
	if r == 0x0A then
		return "\\n"
	elseif r == 0x0D then
		return "\\r"
	elseif r == 0x09 then
		return "\\t"
	elseif r == 0x0C then
		return "\\f"
	elseif r == 0x0B then
		return "\\x0b"
	end

	if r < 0x20 or r == 0x7F then
		return string.format("\\x%02x", r)
	end
	if r > 0x7E then
		return "\\x{" .. hex(r) .. "}"
	end

	local c = string.char(r)
	if string.find("\\.^$|?*+()[]{}", c, 1, true) then
		return "\\" .. c
	end
	return c
end

function Utf8.escapeClassRune(r: number): string
	if r == 0x0A then
		return "\\n"
	elseif r == 0x0D then
		return "\\r"
	elseif r == 0x09 then
		return "\\t"
	elseif r == 0x0C then
		return "\\f"
	elseif r == 0x0B then
		return "\\x0b"
	end

	if r < 0x20 or r == 0x7F then
		return string.format("\\x%02x", r)
	end
	if r > 0x7E then
		return "\\x{" .. hex(r) .. "}"
	end

	local c = string.char(r)
	if c == "\\" or c == "]" or c == "[" or c == "-" or c == "^" then
		return "\\" .. c
	end
	return c
end

return Utf8
