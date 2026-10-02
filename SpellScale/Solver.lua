local _, ns = ...

-- Works out which stat explains a number. Tooltip values are the game's formula rounded to whole
-- numbers, so for each candidate stat there is an exact set of coefficients that reproduces every
-- reading. A wrong stat runs out of them as soon as gear moves the stats in a different
-- proportion. The width of the set that remains is how precisely the coefficient is known.

local Solver = {}
ns.Solver = Solver

local abs, max, min, floor, huge = math.abs, math.max, math.min, math.floor, math.huge

-- Candidate explanations in tie-break order. Stats in one family measure the same thing (spell
-- power per school). If gear never separates them, the first one listed is reported, and the fit
-- still counts as unambiguous.
local STATS = {
	{ key = "sp", short = "SP", name = "Spell Power", family = "sp" },
	{ key = "spx", short = "SP+Heal/3", name = "Spell Power + 1/3 Bonus Healing", family = "sp" },
	{ key = "holy", short = "Holy SP", name = "Holy Spell Power", family = "sp" },
	{ key = "fire", short = "Fire SP", name = "Fire Spell Power", family = "sp" },
	{ key = "nature", short = "Nature SP", name = "Nature Spell Power", family = "sp" },
	{ key = "frost", short = "Frost SP", name = "Frost Spell Power", family = "sp" },
	{ key = "shadow", short = "Shadow SP", name = "Shadow Spell Power", family = "sp" },
	{ key = "arcane", short = "Arcane SP", name = "Arcane Spell Power", family = "sp" },
	{ key = "heal", short = "Healing", name = "Bonus Healing", family = "heal" },
	{ key = "ap", short = "AP", name = "Attack Power", family = "ap" },
	{ key = "rap", short = "RAP", name = "Ranged Attack Power", family = "rap" },
	{ key = "wpn", short = "weapon dmg", name = "Main-hand weapon damage", family = "wpn" },
	{ key = "block", short = "block value", name = "Shield Block Value", family = "block" },
	-- Level before the primary stats: they all rise at a level-up, and classic spells growing
	-- with level is far more common than spells scaling with stamina or agility.
	{ key = "lvl", short = "level", name = "Character level", family = "lvl", perUnit = true },
	{ key = "str", short = "Str", name = "Strength", family = "str" },
	{ key = "agi", short = "Agi", name = "Agility", family = "agi" },
	{ key = "sta", short = "Sta", name = "Stamina", family = "sta" },
	{ key = "int", short = "Int", name = "Intellect", family = "int" },
	{ key = "spi", short = "Spi", name = "Spirit", family = "spi" },
}
ns.STATS = STATS
ns.STAT_BY_KEY = {}
for _, stat in ipairs(STATS) do
	ns.STAT_BY_KEY[stat.key] = stat
end

-- Two readings of one formula, each rounded to the display step, differ from the true difference
-- by less than one step. Looser bounds are a fallback for formulas rounded in more than one place.
local SLACK_TIERS = { 0.999, 2.999, 5.999 }
local MIN_RANGE = 1 -- a stat has to move at least this much to count as tested
local STRICT_MIN_POINTS = 3 -- an exact fit has to cover this many readings to beat a loose one
local PAIR_MIN_POINTS = 5 -- two-stat models need spare readings to be falsifiable
local PAIR_TOL = 0.75 -- worst least-squares residual a two-stat model may leave, in display steps
local COLLINEAR = 1e-3 -- skip stat pairs that have moved in near-lockstep

local function Range(xs, first, last)
	local lo, hi = xs[first], xs[first]
	for k = first + 1, last do
		lo, hi = min(lo, xs[k]), max(hi, xs[k])
	end
	return hi - lo
end

-- The largest spread of xs among readings taken at one character level.
local function WithinLevelRange(xs, levels, first, last)
	local lo, hi, widest = {}, {}, 0
	for k = first, last do
		local level = levels[k]
		lo[level], hi[level] = min(lo[level] or xs[k], xs[k]), max(hi[level] or xs[k], xs[k])
		widest = max(widest, hi[level] - lo[level])
	end
	return widest
end

-- The slopes b for which v = a + b*x reproduces every reading up to rounding. Any two readings
-- must differ by b*dx give or take the slack, so each pair narrows the interval; nil once empty.
-- With levels, the base may grow at each level-up (classic spells gain base damage per level
-- until the rank tops out), but never shrink: readings at one level are compared exactly, and
-- across a level-up the later reading's base can only be higher.
local function SlopeInterval(xs, vs, first, last, slack, levels)
	local lo, hi = -huge, huge
	for i = first, last - 1 do
		for j = i + 1, last do
			local dx, dv = xs[j] - xs[i], vs[j] - vs[i]
			if not levels or levels[i] == levels[j] then
				if dx > 0 then
					lo, hi = max(lo, (dv - slack) / dx), min(hi, (dv + slack) / dx)
				elseif dx < 0 then
					lo, hi = max(lo, (dv + slack) / dx), min(hi, (dv - slack) / dx)
				elseif abs(dv) > slack then
					return nil
				end
			else
				if levels[i] > levels[j] then
					dx, dv = -dx, -dv -- measure from the lower level up
				end
				-- base(higher) - base(lower) = dv - b*dx, which must not be negative
				if dx > 0 then
					hi = min(hi, (dv + slack) / dx)
				elseif dx < 0 then
					lo = max(lo, (dv + slack) / dx)
				elseif dv <= -slack then
					return nil
				end
			end
			if lo > hi then
				return nil
			end
		end
	end
	return lo, hi
end

-- Returns base, coefficient, and the interval the coefficient lies in; nil if this stat can't
-- explain the readings. With levels (base may step up at level-ups), the stat also has to show
-- it matters between level-ups, and the base returned is the latest level's. signedBase lifts
-- the non-negative base rule, for level: "5 + 2 per level" is often written relative to the
-- spell's own level, so the line through level 0 can start below zero.
local function FitLine(xs, vs, first, last, slack, levels, signedBase)
	local range = levels and WithinLevelRange(xs, levels, first, last) or Range(xs, first, last)
	if range < MIN_RANGE then
		return nil
	end
	local lo, hi = SlopeInterval(xs, vs, first, last, slack, levels)
	if not lo or (levels and (lo == -huge or hi == huge or (lo <= 0 and hi >= 0))) then
		-- with free steps at level-ups, a stat only counts if it moved the number between them
		return nil
	end
	-- Tooltip numbers grow with stats, on top of a base that isn't negative: a stat can't
	-- account for more than the whole number. Fits that break either rule are coincidences,
	-- like a talent changing a number at the same moment a gear swap moved some stat.
	lo = max(lo, 0)
	if not signedBase then
		for k = first, last do
			if xs[k] > 0 then
				hi = min(hi, (vs[k] + slack) / xs[k])
			end
		end
	end
	if hi <= lo then
		return nil
	end
	local b = (lo + hi) / 2
	local rlo, rhi = huge, -huge
	for k = first, last do
		if not levels or levels[k] == levels[last] then
			local r = vs[k] - b * xs[k]
			rlo, rhi = min(rlo, r), max(rhi, r)
		end
	end
	return (rlo + rhi) / 2, b, lo, hi
end

-- Least squares v = a + b1*x1 + b2*x2. With levels, each level gets its own base and only the
-- differences within a level are fitted, so base growth at level-ups can't be mistaken for two
-- stats that happened to rise with the level. Returns the latest level's base, b1, b2, the
-- worst residual, the smaller within-level x range, and how many levels the readings span.
local function FitPlane(x1, x2, vs, first, last, levels)
	local groups, count = {}, 0
	for k = first, last do
		local level = levels and levels[k] or 0
		local g = groups[level]
		if not g then
			g = { n = 0, x1 = 0, x2 = 0, v = 0 }
			groups[level], count = g, count + 1
		end
		g.n, g.x1, g.x2, g.v = g.n + 1, g.x1 + x1[k], g.x2 + x2[k], g.v + vs[k]
	end
	local r1 = levels and WithinLevelRange(x1, levels, first, last) or Range(x1, first, last)
	local r2 = levels and WithinLevelRange(x2, levels, first, last) or Range(x2, first, last)
	if r1 < MIN_RANGE or r2 < MIN_RANGE then
		return nil
	end
	local s11, s22, s12, s1v, s2v = 0, 0, 0, 0, 0
	for k = first, last do
		local g = groups[levels and levels[k] or 0]
		local d1, d2, dv = x1[k] - g.x1 / g.n, x2[k] - g.x2 / g.n, vs[k] - g.v / g.n
		s11, s22, s12 = s11 + d1 * d1, s22 + d2 * d2, s12 + d1 * d2
		s1v, s2v = s1v + d1 * dv, s2v + d2 * dv
	end
	local det = s11 * s22 - s12 * s12
	if det <= COLLINEAR * s11 * s22 then
		return nil
	end
	local b1 = (s22 * s1v - s12 * s2v) / det
	local b2 = (s11 * s2v - s12 * s1v) / det
	local worst = 0
	for k = first, last do
		local g = groups[levels and levels[k] or 0]
		local base = (g.v - b1 * g.x1 - b2 * g.x2) / g.n
		worst = max(worst, abs(base + b1 * x1[k] + b2 * x2[k] - vs[k]))
	end
	local g = groups[levels and levels[last] or 0]
	return (g.v - b1 * g.x1 - b2 * g.x2) / g.n, b1, b2, worst, min(r1, r2), count
end

-- Best one-stat explanation of readings [first, last], or nil. When the window spans several
-- levels, each stat is first tried with a base that may step up at level-ups; that interval
-- covers both "the base grew" and "it didn't", so it is the honest one to report. A stat that
-- only fits with a fixed base (it never moved the number between level-ups) is confounded with
-- level, and level is listed as a rival.
local function SingleFit(cols, vs, first, last, prefer, slack, levels)
	local fits = {}
	for _, stat in ipairs(STATS) do
		local xs = cols[stat.key]
		local a, b, lo, hi = nil, nil, nil, nil
		local steps, confounded = false, false
		if levels and stat.key ~= "lvl" then
			a, b, lo, hi = FitLine(xs, vs, first, last, slack, levels)
			if a then
				steps = FitLine(xs, vs, first, last, slack) == nil
			else
				a, b, lo, hi = FitLine(xs, vs, first, last, slack)
				if a then
					-- It only ever moved at level-ups, where the base may have grown too, so
					-- anything from none of the change to all of it could be this stat's.
					confounded = true
					lo = 0
					b = hi / 2
				end
			end
		else
			a, b, lo, hi = FitLine(xs, vs, first, last, slack, nil, stat.key == "lvl")
		end
		if a then
			fits[#fits + 1] = { stat = stat, a = a, b = b, lo = lo, hi = hi, steps = steps, confounded = confounded }
		end
	end
	if #fits == 0 then
		return nil
	end
	-- fits is in priority order, so the first match of a family is that family's best member
	local best = fits[1]
	for _, fit in ipairs(fits) do
		if fit.stat.family == prefer then
			best = fit
			break
		end
	end
	-- Rivals: one stat per other family that fits, plus same-family stats that fit with a
	-- different coefficient (SP vs SP+Heal/3 when healing has only moved alongside spell power).
	local rivals, seen = nil, { [best.stat.family] = true }
	for _, fit in ipairs(fits) do
		local family = fit.stat.family
		local differs = family == best.stat.family and (fit.hi < best.lo or fit.lo > best.hi)
		if differs or not seen[family] then
			seen[family] = true
			rivals = rivals or {}
			rivals[#rivals + 1] = fit.stat.key
		end
	end
	if best.confounded and not seen.lvl then
		rivals = rivals or {}
		rivals[#rivals + 1] = "lvl"
	end
	return {
		kind = "linear",
		a = best.a,
		terms = { { key = best.stat.key, b = best.b } },
		lo = best.lo,
		hi = best.hi,
		err = (best.hi - best.lo) / 2,
		rivals = rivals,
		levelSteps = best.steps or nil,
	}
end

-- Best two-stat explanation of readings [first, last], or nil. Only tried when no single stat
-- fits, for abilities that scale with, say, both attack power and spell power.
local function PairFit(cols, vs, first, last, tolerance, levels)
	local best, rivals
	for i = 1, #STATS do
		for j = i + 1, #STATS do
			local s1, s2 = STATS[i], STATS[j]
			-- level is handled by the stepped base in SingleFit, not as a straight line here
			if s1.family ~= s2.family and s1.key ~= "lvl" and s2.key ~= "lvl" then
				local a, b1, b2, worst, range, groups = FitPlane(cols[s1.key], cols[s2.key], vs, first, last, levels)
				-- two spare readings beyond the two coefficients and one base per level
				local spare = a and (last - first + 1) - groups - 2 >= 2
				if spare and worst <= tolerance and b1 > 0 and b2 > 0 and a >= -tolerance then
					if not best then
						best = { kind = "linear", a = a, terms = { { key = s1.key, b = b1 }, { key = s2.key, b = b2 } }, err = 1 / range }
					else
						rivals = rivals or {}
						rivals[#rivals + 1] = s1.key .. "+" .. s2.key
					end
				end
			end
		end
	end
	if best then
		best.rivals = rivals
	end
	return best
end

-- Explains readings [first, last] of one number, or returns nil if nothing does. The strict pass
-- tries exact rounding with one stat, then two; the loose pass allows tick-built totals.
local function FitWindow(cols, vs, first, last, prefer, step, strict)
	local levels = Range(cols.lvl, first, last) >= 1 and cols.lvl or nil
	local constant = true
	for k = first + 1, last do
		if vs[k] ~= vs[first] then
			constant = false
			break
		end
	end
	if constant then
		local tested
		for _, stat in ipairs(STATS) do
			local range = Range(cols[stat.key], first, last)
			if range >= MIN_RANGE then
				tested = tested or {}
				tested[stat.family] = max(tested[stat.family] or 0, range)
			end
		end
		if tested then
			return { kind = "flat", value = vs[last], tested = tested, n = last - first + 1 }
		end
		return { kind = "unknown" }
	end

	local n = last - first + 1
	local fit
	if strict then
		fit = SingleFit(cols, vs, first, last, prefer, SLACK_TIERS[1] * step, levels)
		if not fit and n >= PAIR_MIN_POINTS then
			fit = PairFit(cols, vs, first, last, PAIR_TOL * step, levels)
		end
	else
		for tier = 2, #SLACK_TIERS do
			fit = SingleFit(cols, vs, first, last, prefer, SLACK_TIERS[tier] * step, levels)
			if fit then
				break
			end
		end
	end
	if fit then
		fit.n = n
	end
	return fit
end

-- The rounding step of a number as displayed: 1 for "87", 0.1 for "1.5". A total made of
-- rounded ticks ("4 ticks of 9" shown as "36 over 12 sec") only ever lands on multiples of the
-- tick count, so that becomes the step once enough different values agree on it. Two or three
-- values sharing a factor is common for round numbers (a block chance going from 20% to 30%).
local function DisplayStep(vs)
	local function divides(step)
		for _, v in ipairs(vs) do
			if abs(v / step - floor(v / step + 0.5)) > 1e-6 then
				return false
			end
		end
		return true
	end
	local step = 1
	while step > 0.001 and not divides(step) do
		step = step / 10
	end
	local distinct, count = {}, 0
	for _, v in ipairs(vs) do
		if not distinct[v] then
			distinct[v], count = true, count + 1
		end
	end
	if count >= 4 then
		for ticks = 8, 2, -1 do
			if divides(step * ticks) then
				return step * ticks
			end
		end
	end
	return step
end

-- points: readings oldest first, each { s = stats, v = { value per slot } }.
-- prefer[slot]: stat family to favour when the data can't tell families apart.
-- Returns one fit per slot:
--   { kind = "linear", a = base, terms = { { key, b }, ... }, err = coefficient uncertainty,
--     lo, hi = the coefficient's interval (one-stat fits), levelSteps = base steps at level-ups,
--     rivals = keys of other stats that fit too (nil once only one does), n = readings used }
--   { kind = "flat", value, tested = { family = how far it moved } }
--   { kind = "unknown" }   no stat has moved yet
-- When something besides stats changes the numbers (a talent, a % damage buff), the readings
-- before that change stop fitting; the history is then cut at a jump in the number, the
-- earliest cut that leaves readings that agree.
function Solver.FitTrack(points, nslots, prefer)
	local n = #points
	local cols = {}
	for _, stat in ipairs(STATS) do
		local xs = {}
		for k = 1, n do
			xs[k] = points[k].s[stat.key] or 0
		end
		cols[stat.key] = xs
	end
	local fits = {}
	for slot = 1, nslots do
		local vs = {}
		for k = 1, n do
			vs[k] = points[k].v[slot]
		end
		local step, favour = DisplayStep(vs), prefer and prefer[slot]
		-- If no formula fits everything, something besides stats changed the number at some
		-- point, and only readings since then can be used. A change like that shows up as a
		-- jump, so those are the only places the history may be cut: cutting anywhere else
		-- would throw away the readings that rule a coincidence out.
		local starts = { 1 }
		for k = 2, n do
			if vs[k] ~= vs[k - 1] then
				starts[#starts + 1] = k
			end
		end
		-- An exact fit to a few readings beats a loose fit to more of them: after a change the
		-- loose bounds could otherwise blend the old formula with the new one.
		local fit
		for _, first in ipairs(starts) do
			if n - first + 1 >= min(STRICT_MIN_POINTS, n) then
				fit = FitWindow(cols, vs, first, n, favour, step, true)
				if fit then
					break
				end
			end
		end
		for _, first in ipairs(starts) do
			if fit then
				break
			end
			fit = FitWindow(cols, vs, first, n, favour, step, false)
		end
		fits[slot] = fit or { kind = "unknown" }
	end
	return fits
end
