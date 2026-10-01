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
	{ key = "str", short = "Str", name = "Strength", family = "str" },
	{ key = "agi", short = "Agi", name = "Agility", family = "agi" },
	{ key = "sta", short = "Sta", name = "Stamina", family = "sta" },
	{ key = "int", short = "Int", name = "Intellect", family = "int" },
	{ key = "spi", short = "Spi", name = "Spirit", family = "spi" },
	{ key = "lvl", short = "level", name = "Character level", family = "lvl", perUnit = true },
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

-- The slopes b for which v = a + b*x reproduces every reading up to rounding. Any two readings
-- must differ by b*dx give or take the slack, so each pair narrows the interval; nil once empty.
local function SlopeInterval(xs, vs, first, last, slack)
	local lo, hi = -huge, huge
	for i = first, last - 1 do
		for j = i + 1, last do
			local dx, dv = xs[j] - xs[i], vs[j] - vs[i]
			if dx > 0 then
				lo, hi = max(lo, (dv - slack) / dx), min(hi, (dv + slack) / dx)
			elseif dx < 0 then
				lo, hi = max(lo, (dv + slack) / dx), min(hi, (dv - slack) / dx)
			elseif abs(dv) > slack then
				return nil
			end
			if lo > hi then
				return nil
			end
		end
	end
	return lo, hi
end

-- Returns base, coefficient, coefficient uncertainty; nil if this stat can't explain the readings.
local function FitLine(xs, vs, first, last, slack)
	if Range(xs, first, last) < MIN_RANGE then
		return nil
	end
	local lo, hi = SlopeInterval(xs, vs, first, last, slack)
	if not lo then
		return nil
	end
	local b = (lo + hi) / 2
	local rlo, rhi = huge, -huge
	for k = first, last do
		local r = vs[k] - b * xs[k]
		rlo, rhi = min(rlo, r), max(rhi, r)
	end
	return (rlo + rhi) / 2, b, (hi - lo) / 2
end

-- Least squares v = a + b1*x1 + b2*x2. Returns a, b1, b2, worst residual, smaller x range.
local function FitPlane(x1, x2, vs, first, last)
	local r1, r2 = Range(x1, first, last), Range(x2, first, last)
	if r1 < MIN_RANGE or r2 < MIN_RANGE then
		return nil
	end
	local n = last - first + 1
	local m1, m2, mv = 0, 0, 0
	for k = first, last do
		m1, m2, mv = m1 + x1[k], m2 + x2[k], mv + vs[k]
	end
	m1, m2, mv = m1 / n, m2 / n, mv / n
	local s11, s22, s12, s1v, s2v = 0, 0, 0, 0, 0
	for k = first, last do
		local d1, d2, dv = x1[k] - m1, x2[k] - m2, vs[k] - mv
		s11, s22, s12 = s11 + d1 * d1, s22 + d2 * d2, s12 + d1 * d2
		s1v, s2v = s1v + d1 * dv, s2v + d2 * dv
	end
	local det = s11 * s22 - s12 * s12
	if det <= COLLINEAR * s11 * s22 then
		return nil
	end
	local b1 = (s22 * s1v - s12 * s2v) / det
	local b2 = (s11 * s2v - s12 * s1v) / det
	local a = mv - b1 * m1 - b2 * m2
	local worst = 0
	for k = first, last do
		worst = max(worst, abs(a + b1 * x1[k] + b2 * x2[k] - vs[k]))
	end
	return a, b1, b2, worst, min(r1, r2)
end

-- Best one-stat explanation of readings [first, last], or nil.
local function SingleFit(cols, vs, first, last, prefer, slack)
	local fits = {}
	for _, stat in ipairs(STATS) do
		local a, b, err = FitLine(cols[stat.key], vs, first, last, slack)
		if a then
			fits[#fits + 1] = { stat = stat, a = a, b = b, err = err }
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
	local rivals, seen = nil, { [best.stat.family] = true }
	for _, fit in ipairs(fits) do
		if not seen[fit.stat.family] then
			seen[fit.stat.family] = true
			rivals = rivals or {}
			rivals[#rivals + 1] = fit.stat.key
		end
	end
	return { kind = "linear", a = best.a, terms = { { key = best.stat.key, b = best.b } }, err = best.err, rivals = rivals }
end

-- Best two-stat explanation of readings [first, last], or nil. Only tried when no single stat
-- fits, for abilities that scale with, say, both attack power and spell power.
local function PairFit(cols, vs, first, last, tolerance)
	local best, rivals
	for i = 1, #STATS do
		for j = i + 1, #STATS do
			local s1, s2 = STATS[i], STATS[j]
			if s1.family ~= s2.family then
				local a, b1, b2, worst, range = FitPlane(cols[s1.key], cols[s2.key], vs, first, last)
				if a and worst <= tolerance then
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
		fit = SingleFit(cols, vs, first, last, prefer, SLACK_TIERS[1] * step)
		if not fit and n >= PAIR_MIN_POINTS then
			fit = PairFit(cols, vs, first, last, PAIR_TOL * step)
		end
	else
		for tier = 2, #SLACK_TIERS do
			fit = SingleFit(cols, vs, first, last, prefer, SLACK_TIERS[tier] * step)
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
-- tick count, so that becomes the step once enough readings agree on it.
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
	if #vs >= 4 then
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
--     rivals = keys of other stats that fit too (nil once only one does), n = readings used }
--   { kind = "flat", value, tested = { family = how far it moved } }
--   { kind = "unknown" }   no stat has moved yet
-- When something besides stats changes the numbers (a talent, a % damage buff), the oldest
-- readings stop fitting; they are dropped one at a time until the recent ones agree again.
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
		-- An exact fit to the last few readings beats a loose fit to all of them: after a change
		-- the loose bounds could otherwise blend the old formula with the new one.
		local fit
		for first = 1, n - min(STRICT_MIN_POINTS, n) + 1 do
			fit = FitWindow(cols, vs, first, n, favour, step, true)
			if fit then
				break
			end
		end
		for first = 1, n - 1 do
			if fit then
				break
			end
			fit = FitWindow(cols, vs, first, n, favour, step, false)
		end
		fits[slot] = fit or { kind = "unknown" }
	end
	return fits
end
