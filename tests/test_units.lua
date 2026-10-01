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

T.section("solver: random formulas")
math.randomseed(1234)
local KEYS = { "sp", "heal", "ap", "rap", "str", "agi", "sta", "int", "spi" }
local trials, wrongStat, outside, ambiguousAtEnd, missing = 2000, 0, 0, 0, 0
for _ = 1, trials do
	local key = KEYS[math.random(#KEYS)]
	local b = math.random(5, 150) / 100
	local a = math.random(5, 300)
	local ticks = math.random() < 0.3 and math.random(3, 6) or 1
	local nearest = math.random() < 0.5
	local function rounder(x) -- whole totals, or totals made of rounded ticks
		x = x / ticks
		return ticks * (nearest and floor(x + 0.5) or floor(x))
	end
	local talentAt = math.random() < 0.3 and math.random(2, 9) or nil -- a talent scales the spell midway
	local cur = { sp = 0, heal = 0, ap = 50, rap = 40, str = 30, agi = 25, sta = 30, int = 35, spi = 40, lvl = 20 }
	local history = {}
	for step = 1, 12 do
		if step == talentAt then
			-- Talents are picked on their own, so the numbers change while the stats don't.
			-- Core.Record wipes a description's readings when that happens; do the same here.
			a, b = a * 1.1, b * 1.1
			history = {}
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
		history[#history + 1] = { s, { rounder(a + b * s[key]) } }
	end
	local pts = {}
	for i, h in ipairs(history) do
		pts[i] = { s = h[1], v = h[2] }
	end
	fit = Solver.FitTrack(pts, 1)[1]
	if fit.kind == "linear" then
		local got = fit.terms[1]
		if got.key ~= key and not fit.rivals then
			wrongStat = wrongStat + 1
		elseif got.key == key and math.abs(got.b - b) > fit.err + 1e-9 then
			outside = outside + 1
		end
		if fit.rivals then
			ambiguousAtEnd = ambiguousAtEnd + 1
			local candidates = { [got.key] = true }
			for _, rival in ipairs(fit.rivals) do
				candidates[rival] = true
			end
			if not (candidates[key] or (ns.STAT_BY_KEY[key].family == "sp" and ns.STAT_BY_KEY[got.key].family == "sp")) then
				missing = missing + 1
			end
		end
	end
end
T.eq(wrongStat, 0, "never confidently names the wrong stat")
T.eq(outside, 0, "the true coefficient is always inside the reported uncertainty")
T.eq(missing, 0, "when unsure, the true stat is among the candidates")
print(format("    %d of %d still ambiguous at the end", ambiguousAtEnd, trials))

T.done()
