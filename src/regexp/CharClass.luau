local Utf8 = require("./Utf8")

local CharClass = {}
CharClass.__index = CharClass

local Runemax = Utf8.Runemax

local function newRangesCopy(ranges)
	local copy = {}
	for _, range in ipairs(ranges or {}) do
		table.insert(copy, { lo = range.lo, hi = range.hi })
	end
	return copy
end

function CharClass.new(ranges)
	return setmetatable({
		ranges = newRangesCopy(ranges),
	}, CharClass)
end

function CharClass:copy()
	return CharClass.new(self.ranges)
end

function CharClass:addRange(lo: number, hi: number)
	if lo > hi then
		lo, hi = hi, lo
	end

	local result = {}
	local inserted = false

	for _, range in ipairs(self.ranges) do
		if hi + 1 < range.lo then
			if not inserted then
				table.insert(result, { lo = lo, hi = hi })
				inserted = true
			end
			table.insert(result, { lo = range.lo, hi = range.hi })
		elseif range.hi + 1 < lo then
			table.insert(result, { lo = range.lo, hi = range.hi })
		else
			lo = math.min(lo, range.lo)
			hi = math.max(hi, range.hi)
		end
	end

	if not inserted then
		table.insert(result, { lo = lo, hi = hi })
	end

	self.ranges = result
	return self
end

function CharClass:addChar(r: number)
	return self:addRange(r, r)
end

function CharClass:addClass(other)
	for _, range in ipairs(other.ranges) do
		self:addRange(range.lo, range.hi)
	end
	return self
end

function CharClass:removeAbove(maxRune: number)
	local result = {}
	for _, range in ipairs(self.ranges) do
		if range.lo <= maxRune then
			table.insert(result, {
				lo = range.lo,
				hi = math.min(range.hi, maxRune),
			})
		end
	end
	self.ranges = result
	return self
end

function CharClass:negate()
	local result = CharClass.new()
	local start = 0
	for _, range in ipairs(self.ranges) do
		if start < range.lo then
			result:addRange(start, range.lo - 1)
		end
		start = range.hi + 1
	end
	if start <= Runemax then
		result:addRange(start, Runemax)
	end
	return result
end

function CharClass:contains(value: number): boolean
	local ranges = self.ranges
	local count = #ranges

	-- Linear scan for small range sets (avoids overhead of binary search)
	if count <= 4 then
		for _, range in ipairs(ranges) do
			if value < range.lo then
				return false
			end
			if value <= range.hi then
				return true
			end
		end
		return false
	end

	-- Binary search for larger range sets
	local lo, hi = 1, count
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local range = ranges[mid]
		if value < range.lo then
			hi = mid - 1
		elseif value > range.hi then
			lo = mid + 1
		else
			return true
		end
	end
	return false
end

function CharClass:size(): number
	local total = 0
	for _, range in ipairs(self.ranges) do
		total += range.hi - range.lo + 1
	end
	return total
end

function CharClass:isEmpty(): boolean
	return #self.ranges == 0
end

function CharClass:isFull(): boolean
	return #self.ranges == 1 and self.ranges[1].lo == 0 and self.ranges[1].hi == Runemax
end

function CharClass:singleRune(): number?
	if #self.ranges == 1 and self.ranges[1].lo == self.ranges[1].hi then
		return self.ranges[1].lo
	end
	return nil
end

function CharClass:equals(other): boolean
	if #self.ranges ~= #other.ranges then
		return false
	end
	for index, range in ipairs(self.ranges) do
		local otherRange = other.ranges[index]
		if range.lo ~= otherRange.lo or range.hi ~= otherRange.hi then
			return false
		end
	end
	return true
end

function CharClass:dumpBody(): string
	local parts = {}
	for _, range in ipairs(self.ranges) do
		if range.lo == range.hi then
			table.insert(parts, Utf8.dumpRune(range.lo))
		else
			table.insert(parts, Utf8.dumpRune(range.lo) .. "-" .. Utf8.dumpRune(range.hi))
		end
	end
	return table.concat(parts, " ")
end

local function classRangeFragment(lo: number, hi: number): string
	local loText = Utf8.escapeClassRune(lo)
	if lo == hi then
		return loText
	end
	local hiText = Utf8.escapeClassRune(hi)
	return loText .. "-" .. hiText
end

function CharClass:classBody(): string
	local parts = {}
	for _, range in ipairs(self.ranges) do
		table.insert(parts, classRangeFragment(range.lo, range.hi))
	end
	return table.concat(parts)
end

function CharClass:toRegex(flags: number): string
	local matchNL = bit32.band(flags, bit32.lshift(1, 2)) ~= 0
	local neverNL = bit32.band(flags, bit32.lshift(1, 6)) ~= 0

	local positive = "[" .. self:classBody() .. "]"
	local negativeRanges = self:negate()
	local negative = "[^" .. negativeRanges:classBody() .. "]"

	if self:isFull() then
		return positive
	end
	if self:isEmpty() then
		return negative
	end

	local canUseNegative = (matchNL and not neverNL) or not self:contains(0x0A)
	if canUseNegative and #negative < #positive then
		return negative
	end
	return positive
end

return CharClass
