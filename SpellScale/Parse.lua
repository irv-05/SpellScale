local _, ns = ...

-- Pulls the numbers out of spell text so the same description can be compared across stat
-- snapshots. A "template" is the visible text with every number replaced by "#": two texts with
-- the same template are the same sentence with different values plugged in.

local Parse = {}
ns.Parse = Parse

local find, sub, byte, gsub, lower = string.find, string.sub, string.byte, string.gsub, string.lower
local concat = table.concat

local PIPE = 124 -- "|"

-- WoW escape sequences start with "|". Returns how many bytes the sequence at i spans and what
-- it contributes to the visible text. Skipping them matters: "|cff71d5ff" is full of digits.
local function EscapeAt(text, i)
	local c = sub(text, i + 1, i + 1)
	if c == "c" then
		if sub(text, i + 2, i + 2) == "n" then -- |cnCOLOR_NAME:
			local colon = find(text, ":", i + 3, true)
			return colon and (colon - i + 1) or 2, ""
		end
		return 10, "" -- |cAARRGGBB
	elseif c == "r" or c == "h" then
		return 2, ""
	elseif c == "n" then
		return 2, "\n"
	elseif c == "|" then
		return 2, "|"
	elseif c == "T" or c == "A" or c == "K" or c == "H" then
		-- textures, atlases, battle.net names, hyperlink payloads: skip to the matching closer
		local close = find(text, "|" .. lower(c), i + 2, true)
		return close and (close - i + 2) or 2, ""
	elseif c == "4" then -- |4singular:plural;
		local semi = find(text, ";", i + 2, true)
		return semi and (semi - i + 1) or 2, ""
	end
	return 1, "|"
end

-- Reads the number starting at i: "87", "1,234", "1.5". Returns its last byte and value.
local function ReadNumber(text, i)
	local _, e = find(text, "^%d+", i)
	while true do
		local _, ge = find(text, "^,%d%d%d", e + 1)
		if ge and not find(text, "^%d", ge + 1) then
			e = ge
		else
			break
		end
	end
	local _, de = find(text, "^%.%d+", e + 1)
	if de then
		e = de
	end
	return e, tonumber((gsub(sub(text, i, e), ",", "")))
end

-- Returns the template of text, plus its numbers as { s = firstByte, e = lastByte, v = value }.
function Parse.Scan(text)
	local parts, nums = {}, {}
	local i = 1
	while true do
		local s = find(text, "[|%d]", i)
		if not s then
			parts[#parts + 1] = sub(text, i)
			break
		end
		if s > i then
			parts[#parts + 1] = sub(text, i, s - 1)
		end
		if byte(text, s) == PIPE then
			local len, visible = EscapeAt(text, s)
			parts[#parts + 1] = visible
			i = s + len
		else
			local e, v = ReadNumber(text, s)
			nums[#nums + 1] = { s = s, e = e, v = v }
			parts[#parts + 1] = "#"
			i = e + 1
		end
	end
	return concat(parts), nums
end

-- Splits a template around its "#" markers: pieces[k] is the text before number k, and
-- pieces[#nums + 1] is the text after the last one.
function Parse.Pieces(template)
	local pieces, i = {}, 1
	while true do
		local s = find(template, "#", i, true)
		if not s then
			pieces[#pieces + 1] = sub(template, i)
			return pieces
		end
		pieces[#pieces + 1] = sub(template, i, s - 1)
		i = s + 1
	end
end

-- Inserts inserts[k] right after number k, past a "%" or colour reset glued to it.
function Parse.Splice(text, nums, inserts)
	local out, last = {}, 0
	for k = 1, #nums do
		local insert = inserts[k]
		if insert then
			local at = nums[k].e
			if sub(text, at + 1, at + 1) == "%" then
				at = at + 1
			end
			if sub(text, at + 1, at + 2) == "|r" then -- land outside the number's colour
				at = at + 2
			end
			out[#out + 1] = sub(text, last + 1, at)
			out[#out + 1] = insert
			last = at
		end
	end
	if last == 0 then
		return text
	end
	out[#out + 1] = sub(text, last + 1)
	return concat(out)
end

local EN_DASH = "\226\128\147"

-- True when the text between two numbers makes them a range: "14 to 23", "14-23".
function Parse.IsRangeGap(gap)
	gap = gsub(gap, "^%s*(.-)%s*$", "%1")
	return gap == "to" or gap == "-" or gap == EN_DASH
end

-- Words that start a new clause rather than describe the number before them.
local CLAUSE = {}
for word in string.gmatch("and or to into for over plus with every per if when while that then in at on by", "%S+") do
	CLAUSE[word] = true
end

-- Up to three words that name what a number is: the words after it ("Fire damage"), or if the
-- clause ends there, the words before it ("heals for").
function Parse.Context(before, after)
	local words = {}
	for word in string.gmatch(string.match(after, "^[^.,;:\n(]*") or "", "%S+") do
		if CLAUSE[lower(word)] then
			break
		end
		words[#words + 1] = word
		if #words == 3 then
			break
		end
	end
	if #words > 0 then
		return concat(words, " ")
	end
	local tail = string.match(before, "([^.,;:\n)]*)$") or ""
	for word in string.gmatch(tail, "%S+") do
		words[#words + 1] = word
	end
	return concat(words, " ", math.max(1, #words - 2))
end
