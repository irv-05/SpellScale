-- Parser edge cases, plus the solver against randomly generated formulas and gear histories.

package.path = "tests/?.lua;" .. package.path
local T = require("check")

local ns = {}
for _, file in ipairs({ "Parse.lua", "Solver.lua" }) do
	assert(loadfile("SpellScale/" .. file))("SpellScale", ns)
end
local Parse, Solver = ns.Parse, ns.Solver
local floor, format = math.floor, string.format

T.section("parse")
local function scan(text)
	local template, nums = Parse.Scan(text)
	local values = {}
	for i, n in ipairs(nums) do
		values[i] = n.v
	end
	return template, table.concat(values, " ")
end

local tpl, vals = scan("Causes 14 to 23 Fire damage.")
T.eq(tpl, "Causes # to # Fire damage.", "plain template")
T.eq(vals, "14 23", "plain values")

tpl, vals = scan("Heals for |cffffffff1,234|r over 1.5 sec, 10% chance.")
T.eq(tpl, "Heals for # over # sec, #% chance.", "colour codes, comma, decimal, percent")
T.eq(vals, "1234 1.5 10", "values through escapes")

tpl, vals = scan("|TInterface\\Icons\\Spell_Fire_123:16|t Hits for 87, 99, and 3,000.")
T.eq(tpl, " Hits for #, #, and #.", "texture path digits are skipped; list commas aren't thousands")
T.eq(vals, "87 99 3000", "list values")

tpl, vals = scan("Casts |Hspell:12345|h[Fireball]|h for |cnNORMAL_FONT_COLOR:5|r |4point:points;.")
T.eq(tpl, "Casts [Fireball] for # .", "hyperlinks, named colours, grammar escapes")
T.eq(vals, "5", "only the visible number")

local text = "Causes |cffffffff14 to 23|r Fire damage and 50% more."
local _, nums = Parse.Scan(text)
T.eq(Parse.Splice(text, nums, { [2] = " (A)", [3] = " (B)" }), "Causes |cffffffff14 to 23|r (A) Fire damage and 50% (B) more.",
	"splice lands after colour resets and percent signs")

T.ok(Parse.IsRangeGap(" to "), "'to' is a range")
T.ok(Parse.IsRangeGap("-"), "'-' is a range")
T.ok(not Parse.IsRangeGap(" into "), "'into' is not")
T.eq(Parse.Context("Causes # to ", " Fire damage and an additional "), "Fire damage", "context after")
T.eq(Parse.Context("Heals your target for ", "."), "your target for", "context before when the sentence ends")
T.eq(Parse.Context("Converts ", " health into "), "health", "context stops at a new clause")

T.section("solver: deterministic cases")
local function stats(t)
	local s = {}
	for _, stat in ipairs(ns.STATS) do
		s[stat.key] = t[stat.key] or 0
	end
	return s
end
local function points(list)
	local out = {}
	for i, p in ipairs(list) do
		out[i] = { s = stats(p[1]), v = p[2] }
	end
	return out
end

-- A DoT whose total is four rounded ticks: (30 + 0.25 * sp) / 4 per tick
local dot = {}
for i, sp in ipairs({ 0, 13, 29, 41, 58, 77, 90 }) do
	dot[i] = { { sp = sp, fire = sp }, { 4 * floor((30 + 0.25 * sp) / 4) } }
end
local fit = Solver.FitTrack(points(dot), 1)[1]
T.eq(fit.kind, "linear", "tick-rounded total still fits")
T.near(fit.terms[1].b, 0.25, fit.err + 1e-9, "tick-rounded coefficient")

-- Two stats that have only ever moved together can't be told apart
fit = Solver.FitTrack(points({
	{ { sp = 0, int = 20 }, { 50 } },
	{ { sp = 10, int = 25 }, { 54 } },
}), 1)[1]
T.ok(fit.rivals ~= nil, "lockstep stats are reported as ambiguous")
-- ...until something moves one of them alone
fit = Solver.FitTrack(points({
	{ { sp = 0, int = 20 }, { 50 } },
	{ { sp = 10, int = 25 }, { 54 } },
	{ { sp = 10, int = 30 }, { 54 } },
}), 1)[1]
T.eq(fit.terms[1].key, "sp", "a lone Int change rules Int out")
T.eq(fit.rivals, nil, "and settles it")

-- Decimal displays use a finer rounding step
fit = Solver.FitTrack(points({
	{ { agi = 20 }, { 1.0 } },
	{ { agi = 40 }, { 2.0 } },
	{ { agi = 53 }, { 2.7 } },
}), 1)[1]
T.eq(fit.terms[1].key, "agi", "decimal value scales with agility")
T.near(fit.terms[1].b, 0.05, 0.004, "decimal coefficient is tight")

T.section("solver: readings from real play")
-- Real readings only list spell power once; every school matched it on the gear they came from.
local function real(list)
	for _, p in ipairs(list) do
		local t = p[1]
		for _, school in ipairs({ "holy", "fire", "nature", "frost", "shadow", "arcane" }) do
			t[school] = t.sp
		end
		t.spx = t.sp + (t.heal or 0) / 3
	end
	return points(list)
end

-- A paladin's Holy Shield block chance went from 20% to 30% at the same moment a gear swap
-- moved spell power, intellect, agility and more. Each of those "explains" the jump on its
-- own, but the first reading (same spell power, still 20%) rules spell power out, and the
-- others need negative coefficients or more than the whole number.
fit = Solver.FitTrack(real({
	{ { sp = 16, heal = 16, ap = 190, rap = 16, wpn = 109.79, block = 2, str = 67, agi = 35, sta = 77, int = 40, spi = 35 }, { 20 } },
	{ { sp = 11, heal = 11, ap = 190, rap = 16, wpn = 109.79, block = 2, str = 67, agi = 35, sta = 77, int = 38, spi = 35 }, { 20 } },
	{ { sp = 6, heal = 6, ap = 190, rap = 16, wpn = 109.79, block = 2, str = 67, agi = 35, sta = 73, int = 38, spi = 35 }, { 20 } },
	{ { sp = 0, heal = 0, ap = 190, rap = 16, wpn = 109.79, block = 2, str = 67, agi = 35, sta = 73, int = 38, spi = 35 }, { 20 } },
	{ { sp = 16, heal = 16, ap = 169, rap = 7, wpn = 89.84, block = 2, str = 61, agi = 31, sta = 66, int = 42, spi = 37 }, { 30 } },
	{ { sp = 16, heal = 16, ap = 165, rap = 3, wpn = 68.64, block = 2, str = 61, agi = 31, sta = 60, int = 42, spi = 43 }, { 30 } },
	{ { sp = 16, heal = 16, ap = 175, rap = 3, wpn = 70.50, block = 13, str = 66, agi = 31, sta = 60, int = 42, spi = 43 }, { 30 } },
}), 1)[1]
T.eq(fit.kind, "flat", "a block chance that jumped with a gear swap isn't pinned on a stat")
T.eq(fit.value, 30, "it reads as its current value")

-- A shaman's Lightning Bolt (rank 2): spell power matters, and the base also rises a point per
-- level. Primary stats rise at every level-up too, which once produced "SP + -54% block value".
fit = Solver.FitTrack(real({
	{ { sp = 5, ap = 58, wpn = 13.20, block = 3, lvl = 9, str = 30, agi = 23, sta = 29, int = 26, spi = 29 }, { 30 } },
	{ { sp = 5, ap = 99, wpn = 19.43, block = 3, lvl = 9, str = 26, agi = 23, sta = 29, int = 26, spi = 29 }, { 30 } },
	{ { sp = 0, ap = 84, wpn = 17.10, block = 4, lvl = 10, str = 42, agi = 23, sta = 30, int = 27, spi = 30 }, { 28 } },
	{ { sp = 5, ap = 62, wpn = 13.80, block = 3, lvl = 10, str = 31, agi = 19, sta = 30, int = 27, spi = 30 }, { 30 } },
	{ { sp = 5, ap = 127, wpn = 47.09, block = 1, lvl = 10, str = 39, agi = 23, sta = 28, int = 27, spi = 31 }, { 30 } },
	{ { sp = 5, ap = 117, wpn = 45.16, block = 1, lvl = 11, str = 33, agi = 24, sta = 31, int = 28, spi = 32 }, { 31 } },
	{ { sp = 5, ap = 117, wpn = 45.16, block = 1, lvl = 11, str = 33, agi = 24, sta = 29, int = 28, spi = 32 }, { 31 } },
	{ { sp = 5, ap = 125, wpn = 46.70, block = 1, lvl = 11, str = 37, agi = 24, sta = 31, int = 28, spi = 32 }, { 31 } },
	{ { sp = 5, ap = 127, wpn = 47.09, block = 1, lvl = 11, str = 38, agi = 24, sta = 31, int = 28, spi = 32 }, { 31 } },
	{ { sp = 0, ap = 127, wpn = 47.09, block = 1, lvl = 11, str = 38, agi = 24, sta = 31, int = 28, spi = 32 }, { 28 } },
	{ { sp = 0, ap = 125, wpn = 46.70, block = 1, lvl = 11, str = 37, agi = 24, sta = 31, int = 28, spi = 32 }, { 28 } },
	{ { sp = 0, ap = 137, wpn = 49.02, block = 1, lvl = 11, str = 43, agi = 24, sta = 31, int = 30, spi = 46 }, { 28 } },
}), 1)[1]
T.eq(fit.kind == "linear" and #fit.terms == 1 and fit.terms[1].key, "sp", "Lightning Bolt scales with spell power alone")
T.ok(fit.levelSteps, "with a base that rises with level")
T.ok(fit.lo >= 0.3 and fit.hi <= 0.7, string.format("and a sane coefficient (%.2f-%.2f)", fit.lo, fit.hi))

T.section("solver: random formulas")
-- Each trial invents a spell: base + coefficient * stat, where many classic spells' base also
-- grows with level up to a cap (as seen on a real shaman). Twelve readings follow random gear
-- swaps, level-ups (which raise the primary stats and attack power too) and sometimes a talent.
math.randomseed(1234)
local KEYS = { "sp", "heal", "ap", "rap", "str", "agi", "sta", "int", "spi" }
local PRIMARY = { "str", "agi", "sta", "int", "spi" }
local trials, wrongStat, outside, ambiguousAtEnd, missing = 2000, 0, 0, 0, 0
for _ = 1, trials do
	local key = KEYS[math.random(#KEYS)]
	local b = math.random(5, 150) / 100
	local a = math.random(5, 300)
	local perLevel = math.random() < 0.4 and math.random(1, 4) / 2 or 0
	local cap = 20 + math.random(0, 4)
	local nearest = math.random() < 0.5
	local function rounder(x)
		return nearest and floor(x + 0.5) or floor(x)
	end
	local talentAt = math.random() < 0.3 and math.random(2, 9) or nil
	local cur = { sp = 0, heal = 0, ap = 50, rap = 40, str = 30, agi = 25, sta = 30, int = 35, spi = 40, lvl = 20 }
	local history = {}
	for step = 1, 12 do
		if step == talentAt then
			-- Talents are picked on their own, so the numbers change while the stats don't.
			-- Core.Record wipes a description's readings when that happens; do the same here.
			a, b = a * 1.1, b * 1.1
			history = {}
		elseif step > 1 and math.random() < 0.25 then
			cur.lvl = cur.lvl + 1
			for _, k in ipairs(PRIMARY) do
				cur[k] = cur[k] + math.random(0, 2)
			end
			cur.ap = cur.ap + 2
		elseif step > 1 then
			-- a gear swap moves one to three stats by random amounts
			for _ = 1, math.random(3) do
				local k = KEYS[math.random(#KEYS)]
				cur[k] = math.max(0, cur[k] + math.random(-8, 25))
			end
		end
		local s = {}
		for k, v in pairs(cur) do
			s[k] = v
		end
		s.fire, s.holy, s.nature, s.frost, s.shadow, s.arcane = s.sp, s.sp, s.sp, s.sp, s.sp, s.sp
		s.spx = s.sp + s.heal / 3
		local base = a + perLevel * (math.min(s.lvl, cap) - 20)
		history[#history + 1] = { s, { rounder(base + b * s[key]) } }
	end
	local pts, lo, hi = {}, {}, {}
	local identifiable = false
	for i, h in ipairs(history) do
		pts[i] = { s = h[1], v = h[2] }
		local level, x = h[1].lvl, h[1][key]
		lo[level], hi[level] = math.min(lo[level] or x, x), math.max(hi[level] or x, x)
		-- identifiable: between level-ups the stat moved enough to shift the number a whole point
		identifiable = identifiable or (hi[level] - lo[level]) * b >= 1
	end
	fit = Solver.FitTrack(pts, 1)[1]
	if fit.kind == "linear" then
		local named = {}
		for _, t in ipairs(fit.terms) do
			named[t.key] = t
		end
		if named[key] then
			if #fit.terms == 1 and math.abs(named[key].b - b) > fit.err + 1e-9 then
				outside = outside + 1
			end
		elseif not fit.rivals then
			-- Naming some other stat outright is always wrong. Naming level outright is only
			-- wrong if the stat visibly moved the number between level-ups.
			if fit.terms[1].key ~= "lvl" or identifiable then
				wrongStat = wrongStat + 1
			end
		end
		if fit.rivals then
			ambiguousAtEnd = ambiguousAtEnd + 1
			local candidates = {}
			for _, t in ipairs(fit.terms) do
				candidates[t.key] = true
			end
			for _, rival in ipairs(fit.rivals) do
				for part in rival:gmatch("[^+]+") do
					candidates[part] = true
				end
			end
			if identifiable and not candidates[key] then
				missing = missing + 1
			end
		end
	end
end
T.eq(wrongStat, 0, "never confidently names the wrong stat")
T.eq(outside, 0, "the true coefficient is always inside the reported uncertainty")
T.eq(missing, 0, "when unsure and the data could show it, the true stat is among the candidates")
print(format("    %d of %d still ambiguous at the end", ambiguousAtEnd, trials))

T.done()
