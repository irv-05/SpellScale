-- Plays a short session against the fake client: log in, swap gear, buff, level, change a
-- talent, fight. Then checks the addon recovered the formulas the fake spells were built from.

package.path = "tests/?.lua;" .. package.path
local M = require("mock_wow")
local T = require("check")

local format, floor = string.format, math.floor
local function round(x)
	return floor(x + 0.5)
end
local function commas(n)
	local s = tostring(n)
	return s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local talent = 1 -- multiplier from a +10% fire damage talent, applied later

M.spells = {
	[133] = { name = "Fireball", rank = "Rank 2", desc = function(p)
		local fire = p.school[3]
		return format("Hurls a fiery ball that causes %d to %d Fire damage and an additional %d Fire damage over 4 sec.",
			floor((14 + 0.429 * fire) * talent), floor((23 + 0.429 * fire) * talent), floor(2 + 0.2 * fire))
	end },
	-- colour codes around the numbers; scales with nature power plus a third of bonus healing
	[5176] = { name = "Wrath", rank = "Rank 3", desc = function(p)
		local power = p.school[4] + p.heal / 3
		return format("Causes |cffffffff%d to %d|r Nature damage to the target.", round(25 + 0.571 * power), round(32 + 0.571 * power))
	end },
	[2050] = { name = "Lesser Heal", rank = "Rank 2", desc = function(p)
		return format("Heal your target for %d to %d.", round(71 + 0.6 * p.heal), round(85 + 0.6 * p.heal))
	end },
	[2060] = { name = "Greater Heal", desc = function(p)
		return format("A slow casting spell that heals a single target for %s.", commas(round(1000 + 1.0 * p.heal)))
	end },
	[78] = { name = "Heroic Strike", desc = function(p)
		return format("A strong attack that increases melee damage by %d and causes a high amount of threat.", floor(11 + 0.2 * p.ap))
	end },
	[1459] = { name = "Arcane Intellect", desc = function()
		return "Increases the target's Intellect by 7 for 30 min."
	end },
	[1454] = { name = "Life Tap", desc = function(p)
		local v = floor(30 + 0.8 * p.stats[5])
		return format("Converts %d health into %d mana.", v, v)
	end },
	[20154] = { name = "Seal of Righteousness", desc = function(p)
		return format("Fills you with Holy spirit for 30 sec. Each melee attack deals %d additional Holy damage.",
			round(10 + 0.15 * p.ap + 0.25 * p.school[2]))
	end },
	[6673] = { name = "Battle Shout", desc = function(p)
		return format("Increases the attack power of party members within 20 yards by %d for 2 min.", 5 + 2 * p.lvl)
	end },
}
M.book = { 133, 5176, 2050, 2060, 78, 1459, 1454, 20154, 6673 }

M.load("SpellScale")
local ns = M.ns
M.fire("PLAYER_ENTERING_WORLD")
M.advance(3)

local function track(id)
	local spell = ns.char.spells[id]
	return spell.tracks[spell.cur], spell.cur
end
local function fits(id)
	local tr, tpl = track(id)
	return ns.GetFits(tr, tpl)
end
local function term(fit)
	return fit.terms[1]
end

T.section("first login")
for _, id in ipairs(M.book) do
	T.eq(#track(id).obs, 1, M.spells[id].name .. " has one reading")
	T.eq(ns.TrackStatus(track(id)), "learning", M.spells[id].name .. " is learning")
end

T.section("gear, buffs, level")
M.change(function(p) -- staff: spell damage and healing, some int and stamina
	M.addSpellDamage(p, 12)
	p.heal = p.heal + 12
	p.stats[4], p.stats[3] = p.stats[4] + 5, p.stats[3] + 3
end)
M.change(function(p) -- ring of fire power
	p.school[3] = p.school[3] + 5
end)
M.change(function(p) -- arcane intellect
	p.stats[4] = p.stats[4] + 4
end)
M.change(function(p) -- healing trinket
	p.heal = p.heal + 15
end)
M.change(function(p) -- spirit scroll
	p.stats[5] = p.stats[5] + 6
end)
M.change(function(p) -- level up
	p.lvl = p.lvl + 1
	for i, gain in ipairs({ 1, 1, 2, 2, 2 }) do
		p.stats[i] = p.stats[i] + gain
	end
	p.ap = p.ap + 2
end)
M.change(function(p) -- attack power ring
	p.ap = p.ap + 20
end)
M.change(function(p) -- strength and agility gloves (strength feeds attack power)
	p.stats[1], p.stats[2] = p.stats[1] + 4, p.stats[2] + 3
	p.ap = p.ap + 8
end)
M.change(function(p) -- holy power belt
	p.school[2] = p.school[2] + 8
end)
M.change(function(p)
	p.ap = p.ap + 10
	p.school[2] = p.school[2] + 3
end)

local f = fits(133)
T.eq(f[1].kind, "linear", "Fireball low end scales")
T.eq(term(f[1]).key, "fire", "Fireball scales with fire power specifically")
T.near(term(f[1]).b, 0.429, f[1].err + 1e-9, "Fireball coefficient")
T.ok(f[1].err < 0.07, "Fireball coefficient is pinned down (err " .. f[1].err .. ")")
T.eq(f[3].kind, "linear", "Fireball DoT scales")
T.eq(term(f[3]).key, "fire", "Fireball DoT scales with fire power")
T.eq(f[3].rivals, nil, "Fireball DoT is unambiguous")
T.eq(f[4].kind, "flat", "Fireball DoT duration doesn't scale")
T.near(term(f[3]).b, 0.2, f[3].err + 1e-9, "Fireball DoT coefficient")
local groups = ns.Groups(track(133))
T.eq(#groups, 2, "Fireball has two scaling parts")
T.eq(groups[1].first .. "-" .. groups[1].last, "1-2", "the 14 to 23 range is grouped")
T.eq(groups[1].context, "Fire damage", "range context")

f = fits(5176)
T.eq(term(f[1]).key, "spx", "Wrath picks up the healing-to-damage rule")
T.near(term(f[1]).b, 0.571, f[1].err + 1e-9, "Wrath coefficient")

f = fits(2050)
T.eq(term(f[1]).key, "heal", "Lesser Heal scales with healing")
T.eq(f[1].rivals, nil, "Lesser Heal is unambiguous")
T.near(term(f[1]).b, 0.6, f[1].err + 1e-9, "Lesser Heal coefficient")

f = fits(2060)
T.eq(term(f[1]).key, "heal", "Greater Heal (1,0xx with a thousands comma)")
T.near(term(f[1]).b, 1.0, f[1].err + 1e-9, "Greater Heal coefficient")

f = fits(78)
T.eq(term(f[1]).key, "ap", "Heroic Strike scales with AP")
T.near(term(f[1]).b, 0.2, f[1].err + 1e-9, "Heroic Strike coefficient")
T.eq(f[1].rivals, nil, "Heroic Strike is unambiguous after the AP ring")

T.eq(ns.TrackStatus(track(1459)), "flat", "Arcane Intellect doesn't scale")

f = fits(1454)
T.eq(term(f[1]).key, "spi", "Life Tap scales with spirit")
T.near(term(f[1]).b, 0.8, f[1].err + 1e-9, "Life Tap coefficient")

f = fits(20154)
T.eq(f[1].kind, "flat", "Seal duration doesn't scale")
T.eq(#f[2].terms, 2, "Seal damage scales with two stats")
T.eq(f[2].terms[1].key .. "+" .. f[2].terms[2].key, "holy+ap", "Seal stats")
T.near(f[2].terms[1].b, 0.25, 0.05, "Seal holy coefficient")
T.near(f[2].terms[2].b, 0.15, 0.05, "Seal AP coefficient")

f = fits(6673)
T.eq(f[1].kind, "flat", "Battle Shout range doesn't scale")
T.eq(term(f[2]).key, "lvl", "Battle Shout scales with level")
T.eq(ns.FormatFit(f[2]), "+2.0 per level", "per-level formatting")

T.section("talent changes the numbers but not the stats")
M.advance(30)
talent = 1.1
M.fire("CHARACTER_POINTS_CHANGED")
M.advance(1)
T.eq(#track(133).obs, 1, "Fireball forgets readings from before the talent")
T.eq(ns.TrackStatus(track(133)), "learning", "Fireball relearns")
T.eq(#track(2050).obs > 1, true, "Lesser Heal keeps its readings")
M.change(function(p)
	p.school[3] = p.school[3] + 30
end)
M.change(function(p)
	M.addSpellDamage(p, 40)
end)
f = fits(133)
T.eq(term(f[1]).key, "fire", "Fireball relearned")
T.near(term(f[1]).b, 0.429 * 1.1, f[1].err + 1e-9, "Fireball coefficient includes the talent")

T.section("combat")
local function latestHeal()
	local obs = track(2050).obs
	return ns.char.snaps[obs[#obs].s].heal
end
local before = latestHeal()
M.player.inCombat = true
M.change(function(p)
	p.heal = p.heal + 9
end)
T.eq(latestHeal(), before, "nothing is read in combat")
M.player.inCombat = false
M.fire("PLAYER_REGEN_ENABLED")
M.advance(2)
T.eq(latestHeal(), before + 9, "reading taken after combat")

T.section("tooltips")
local lines = M.showSpellTooltip(133)
print("    " .. lines[3])
T.ok(lines[3]:find("^Hurls a fiery ball that causes %d+ to %d+ |cff7fc8ff%(~?47[%.%d]*%% Fire SP%)|r Fire damage") ~= nil,
	"Fireball range annotated once, after its second number")
T.ok(lines[3]:find("additional %d+ |cff7fc8ff%(~?20[%.%d]*%% Fire SP%)|r Fire damage over 4 sec%.$") ~= nil, "Fireball DoT annotated")
T.eq(lines[2], "1.5 sec cast", "other lines untouched")
T.eq(#lines, 3, "no hint line on a learned spell")

lines = M.showSpellTooltip(5176)
print("    " .. lines[3])
T.ok(lines[3]:find("^Causes |cffffffff%d+ to %d+|r |cff7fc8ff%(.-SP%+Heal/3%)|r Nature damage") ~= nil,
	"Wrath annotated after its colour code")

lines = M.showSpellTooltip(1459)
T.eq(lines[3], "Increases the target's Intellect by 7 for 30 min.", "flat spell left alone")
T.eq(#lines, 3, "no hint on a spell that doesn't scale")

M.spells[999] = { name = "New Spell", desc = function(p)
	return format("Deals %d damage.", 10 + p.school[3])
end }
lines = M.showSpellTooltip(999)
T.eq(lines[4], "|cff808080SpellScale: still learning (needs a stat change)|r", "hint on a spell seen once")

T.section("a stat change no event announced")
local readings = #track(2050).obs
M.player.heal = M.player.heal + 20 -- no event fired
M.advance(0.1) -- next frame
M.showSpellTooltip(2050)
T.eq(#track(2050).obs, readings, "the hover doesn't pair new text with stale stats")
M.advance(1)
local obs = track(2050).obs
T.eq(ns.char.snaps[obs[#obs].s].heal, M.player.heal, "it schedules a sweep that records it properly")

T.section("speed")
for id = 10000, 10149 do
	M.spells[id] = { name = "Filler " .. id, desc = function(p)
		return format("Deals %d to %d Shadow damage, then %d more over %d sec. Costs %d mana.",
			floor(20 + 0.3 * p.school[6] + id % 7), floor(30 + 0.3 * p.school[6]), floor(5 + 0.1 * p.ap), 12, 40)
	end }
	M.book[#M.book + 1] = id
end
for i = 1, 12 do
	M.change(function(p)
		M.addSpellDamage(p, 3 + i)
		p.ap = p.ap + (i % 3) * 5
		p.stats[i % 5 + 1] = p.stats[i % 5 + 1] + 2
	end)
end
local started = os.clock()
for _, spell in pairs(ns.char.spells) do
	ns.TrackStatus(spell.tracks[spell.cur], spell.cur)
end
local elapsed = os.clock() - started
print(format("    solving %d spells from scratch took %.0f ms", #M.book, elapsed * 1000))
T.ok(elapsed < 0.25, "solving a full spellbook is quick")

T.section("talent tree")
M.spells[20375] = { name = "Seal of Command", desc = function(p)
	local j = 74 + 0.43 * p.school[2]
	return format("Gives the Paladin a chance to deal additional Holy damage equal to 70%% of normal weapon damage. "
		.. "Lasts 30 sec. Unleashing this Seal's energy will judge an enemy, instantly causing %d Holy damage, "
		.. "%d to %d if the target is stunned or incapacitated.", floor(j), floor(j * 1.85), floor(j * 2))
end }
M.spells[31001] = { name = "Choice A", desc = function(p)
	return format("Deals %d Holy damage.", floor(10 + 0.5 * p.school[2]))
end }
M.spells[31002] = { name = "Choice B", desc = function(p)
	return format("Heals for %d.", floor(10 + 0.5 * p.heal))
end }
M.spells[31003] = { name = "Hidden", desc = function()
	return "Does 5 things."
end }
M.talents = {
	[1] = { entries = { 20375 }, ranks = 0 }, -- Seal of Command, not taken, not in the spellbook
	[2] = { entries = { 20154 }, ranks = 1 }, -- Seal of Righteousness: taken and in the spellbook
	[3] = { entries = { 31001, 31002 }, ranks = 1, active = 31002 }, -- a choice node
	[4] = { entries = { 31003 }, ranks = 0, hidden = true },
}
for i = 1, 3 do
	M.change(function(p)
		p.school[2] = p.school[2] + 10 * i
		p.heal = p.heal + 5
	end)
end
local soc = ns.char.spells[20375]
T.ok(soc ~= nil, "an untaken talent is read without being in the spellbook")
T.eq(soc and soc.talent, "untaken", "and marked as not taken")
f = fits(20375)
T.eq(f[1].kind, "flat", "Seal of Command's 70% is already a formula")
T.eq(f[2].kind, "flat", "and its duration doesn't scale")
T.eq(term(f[3]).key, "holy", "its judgement scales with holy power")
T.near(term(f[3]).b, 0.43, f[3].err + 1e-9, "judgement coefficient")
T.near(term(f[5]).b, 0.86, f[5].err + 1e-9, "stunned judgement coefficient")
T.eq(ns.char.spells[20154].talent, "taken", "a talent you have is marked as taken")
T.eq(ns.char.spells[31001].talent, "untaken", "the unchosen side of a choice node")
T.eq(ns.char.spells[31002].talent, "taken", "the chosen side of a choice node")
T.eq(ns.char.spells[31003], nil, "hidden talent nodes are skipped")
lines = M.showSpellTooltip(20375)
print("    " .. lines[3])
T.ok(lines[3]:find("instantly causing %d+ |cff7fc8ff%(4[23][%.%d]*%% Holy SP%)|r Holy damage") ~= nil, "talent tooltip annotated")

T.section("tooltip title guard")
local readingsBefore = #track(2050).obs
M.change(function(p)
	p.heal = p.heal + 11
end)
local afterSweep = #track(2050).obs
lines = M.showSpellTooltip(2050, "Some Other Spell")
T.eq(lines[3]:find("|cff7fc8ff", 1, true), nil, "a tooltip titled with another name is left alone")
T.ok(afterSweep >= readingsBefore, "sanity")

T.section("window")
SlashCmdList.SPELLSCALE("")
T.ok(SpellScaleFrame:IsShown(), "/ss opens the window")
SlashCmdList.SPELLSCALE("spell Fireball")
SlashCmdList.SPELLSCALE("")
T.ok(not SpellScaleFrame:IsShown(), "/ss closes it again")

T.section("saved data")
local snaps = 0
for _ in pairs(ns.char.snaps) do
	snaps = snaps + 1
end
M.fire("PLAYER_LOGOUT")
local kept = 0
for _ in pairs(ns.char.snaps) do
	kept = kept + 1
end
T.ok(kept <= snaps and kept > 0, format("logout keeps %d of %d snapshots", kept, snaps))

T.done()
