local addonName, ns = ...

-- Learning loop: whenever your stats settle out of combat, read every spellbook description and
-- file its numbers next to a snapshot of your stats. The solver turns those pairs into formulas.
-- Forever hides the combat log from addons, but its tooltips are live (they already include your
-- spell power), so the formula can be read off them directly, and exactly.

local Parse, Solver = ns.Parse, ns.Solver
local STATS = ns.STATS

local format, find, lower, concat = string.format, string.find, string.lower, table.concat
local floor, abs = math.floor, math.abs

local issecret = issecretvalue or function()
	return false
end

local DB_VERSION = 1
local MAX_OBS = 12 -- readings kept per description
local MAX_TRACKS = 3 -- description variants kept per spell
local SETTLE = 0.5 -- seconds of quiet after a stat change before sampling

local DEFAULTS = { tooltips = true, hints = true }

-------------------------------------------------------------------------------
-- Stats
-------------------------------------------------------------------------------

local SCHOOLS = { [2] = "holy", [3] = "fire", [4] = "nature", [5] = "frost", [6] = "shadow", [7] = "arcane" }
local PRIMARY = { "str", "agi", "sta", "int", "spi" }

-- Returns the player's stats, or nil if any of them is unavailable (secret during combat).
function ns.ReadStats()
	local s = {}
	local function put(key, v)
		if v == nil or issecret(v) then
			return false
		end
		s[key] = v
		return true
	end
	for school, key in pairs(SCHOOLS) do
		if not put(key, GetSpellBonusDamage(school)) then
			return nil
		end
		s.sp = s.sp and math.min(s.sp, s[key]) or s[key] -- the character sheet's "Spell Power"
	end
	if not put("heal", GetSpellBonusHealing()) then
		return nil
	end
	s.spx = s.sp + s.heal / 3

	local base, pos, neg = UnitAttackPower("player")
	if issecret(base) or issecret(pos) or issecret(neg) then
		return nil
	end
	s.ap = (base or 0) + (pos or 0) + (neg or 0)
	base, pos, neg = UnitRangedAttackPower("player")
	if issecret(base) or issecret(pos) or issecret(neg) then
		return nil
	end
	s.rap = (base or 0) + (pos or 0) + (neg or 0)

	for i, key in ipairs(PRIMARY) do
		local _, effective = UnitStat("player", i)
		if not put(key, effective or 0) then
			return nil
		end
	end
	local lo, hi = UnitDamage("player")
	if issecret(lo) or issecret(hi) then
		return nil
	end
	s.wpn = floor(((lo or 0) + (hi or 0)) / 2 * 100 + 0.5) / 100
	if not put("block", GetShieldBlock() or 0) then
		return nil
	end
	s.lvl = UnitLevel("player")
	return s
end

local function SnapshotKey(s)
	local parts = {}
	for i, stat in ipairs(STATS) do
		parts[i] = tostring(s[stat.key])
	end
	return concat(parts, ",")
end

-- Observations reference snapshots by id so SavedVariables stores each stat set once.
local snapIndex = {}

function ns.InternSnapshot(s)
	local key = SnapshotKey(s)
	local id = snapIndex[key]
	if not id then
		local db = ns.char
		id = db.nextSnap
		db.nextSnap = id + 1
		db.snaps[id] = s
		snapIndex[key] = id
	end
	return id
end

-------------------------------------------------------------------------------
-- Observations
-------------------------------------------------------------------------------

local fitCache = setmetatable({}, { __mode = "k" })
local lastWrite = setmetatable({}, { __mode = "k" }) -- GetTime() of each track's latest observation
local piecesCache = {}

local function SameValues(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function PruneTracks(spell)
	local count, oldestKey, oldestSeen = 0, nil, math.huge
	for template, track in pairs(spell.tracks) do
		count = count + 1
		if template ~= spell.cur and (track.seen or 0) < oldestSeen then
			oldestKey, oldestSeen = template, track.seen or 0
		end
	end
	if count > MAX_TRACKS and oldestKey then
		spell.tracks[oldestKey] = nil
	end
end

-- The reading to drop when a description has too many: the oldest one that isn't the lone
-- minimum or maximum of some stat, since the extremes are what pin coefficients down.
local function Expendable(obs)
	local snaps = ns.char.snaps
	local keep = {}
	for _, stat in ipairs(STATS) do
		local lo, hi, nlo, nhi, klo, khi
		for k, o in ipairs(obs) do
			local x = snaps[o.s] and snaps[o.s][stat.key] or 0
			if not lo or x < lo then
				lo, nlo, klo = x, 1, k
			elseif x == lo then
				nlo = nlo + 1
			end
			if not hi or x > hi then
				hi, nhi, khi = x, 1, k
			elseif x == hi then
				nhi = nhi + 1
			end
		end
		if nlo == 1 then
			keep[klo] = true
		end
		if nhi == 1 then
			keep[khi] = true
		end
	end
	for k = 1, #obs - 1 do
		if not keep[k] then
			return k
		end
	end
	return 1
end

-- Files one reading of a spell's text under the stat snapshot sid.
function ns.Record(spellID, text, sid)
	local template, nums = Parse.Scan(text)
	if #nums == 0 then
		return false
	end
	local spells = ns.char.spells
	local spell = spells[spellID]
	if not spell then
		spell = { tracks = {} }
		spells[spellID] = spell
	end
	spell.name = C_Spell.GetSpellName(spellID) or spell.name
	spell.rank = C_Spell.GetSpellSubtext(spellID) or spell.rank
	spell.icon = C_Spell.GetSpellTexture(spellID) or spell.icon
	spell.cur = template

	local track = spell.tracks[template]
	if not track then
		track = { obs = {} }
		spell.tracks[template] = track
		PruneTracks(spell)
	end
	track.seen = time()

	local values = {}
	for i, num in ipairs(nums) do
		values[i] = num.v
	end
	local obs = track.obs
	for k = #obs, 1, -1 do
		if obs[k].s == sid then
			if SameValues(obs[k].v, values) then
				return false
			end
			if k == #obs and GetTime() - (lastWrite[track] or -math.huge) < 2 then
				-- The text caught up with a stat change after we first read it: keep the newer reading.
				obs[k].v = values
				fitCache[track] = nil
				lastWrite[track] = GetTime()
				return true
			end
			-- Same stats, different numbers: something other than gear moved them (talents, a
			-- % damage buff). Nothing recorded before is comparable any more.
			wipe(obs)
			break
		end
	end
	obs[#obs + 1] = { s = sid, v = values }
	if #obs > MAX_OBS then
		table.remove(obs, Expendable(obs))
	end
	fitCache[track] = nil
	lastWrite[track] = GetTime()
	return true
end

-------------------------------------------------------------------------------
-- Results
-------------------------------------------------------------------------------

function ns.Pieces(template)
	local pieces = piecesCache[template]
	if not pieces then
		pieces = Parse.Pieces(template)
		piecesCache[template] = pieces
	end
	return pieces
end

-- Which stat family the sentence around number k is about, used to break ties between stats
-- that gear has so far moved together (e.g. "spell damage and healing" items).
local function PreferredFamily(pieces, k)
	local after = lower(concat(pieces, "#", k + 1)):match("^[^.]*")
	local before = lower(concat(pieces, "#", 1, k)):match("[^.]*$")
	for _, text in ipairs({ after, before }) do
		if find(text, "physical") or find(text, "weapon") or find(text, "attack power") then
			return "ap"
		end
		local d = find(text, "damage", 1, true)
		local h = find(text, "%f[%a]heal[^t]") or find(text, "%f[%a]heal$")
		if d and (not h or d < h) then
			return "sp"
		elseif h then
			return "heal"
		end
	end
end

function ns.GetFits(track, template)
	local fits = fitCache[track]
	if fits then
		return fits
	end
	local pieces = ns.Pieces(template)
	local nslots = #pieces - 1
	local prefer = {}
	for k = 1, nslots do
		prefer[k] = PreferredFamily(pieces, k)
	end
	local points, snaps = {}, ns.char.snaps
	for i, o in ipairs(track.obs) do
		points[i] = { s = snaps[o.s] or {}, v = o.v }
	end
	fits = Solver.FitTrack(points, nslots, prefer)
	fitCache[track] = fits
	return fits
end

local function Round(x)
	return floor(x + 0.5)
end

local function FormatTerm(term, err)
	local stat = ns.STAT_BY_KEY[term.key]
	if stat.perUnit then
		return format("%+.1f per %s", term.b, stat.short)
	end
	local pct, pctErr = term.b * 100, err * 100
	if pctErr < 0.5 then
		return format("%.1f%% %s", pct, stat.short)
	elseif pctErr < 5 then
		return format("%d%% %s", Round(pct), stat.short)
	end
	return format("~%d%% %s", Round(pct), stat.short)
end

-- "42.9% SP", "~40% SP?", "20% AP + 10% SP"
function ns.FormatFit(fit)
	local parts = {}
	for i, term in ipairs(fit.terms) do
		parts[i] = FormatTerm(term, fit.err)
	end
	return concat(parts, " + ") .. (fit.rivals and "?" or "")
end

function ns.FormatNumber(v)
	if abs(v - Round(v)) < 0.05 then
		return tostring(Round(v))
	end
	return format("%.1f", v)
end

local function SameTerms(f1, f2)
	if f2.kind ~= "linear" or #f1.terms ~= #f2.terms then
		return false
	end
	local slack = f1.err + f2.err + 0.001 -- the two coefficient intervals overlap
	for i, term in ipairs(f1.terms) do
		local other = f2.terms[i]
		if other.key ~= term.key or abs(other.b - term.b) > slack then
			return false
		end
	end
	return true
end

-- The scaling numbers of a description, with "14 to 23" ranges merged into one group:
-- { first = slot, last = slot, fit = fit, context = "Fire damage" }
function ns.Groups(track, template)
	local fits = ns.GetFits(track, template)
	local pieces = ns.Pieces(template)
	local groups = {}
	local k = 1
	while k <= #fits do
		local fit = fits[k]
		if fit.kind == "linear" then
			local last = k
			if fits[k + 1] and SameTerms(fit, fits[k + 1]) and Parse.IsRangeGap(pieces[k + 1]) then
				last = k + 1
				if fits[last].err < fit.err then
					fit = fits[last]
				end
			end
			groups[#groups + 1] = {
				first = k,
				last = last,
				fit = fit,
				context = Parse.Context(pieces[k], pieces[last + 1]),
			}
			k = last + 1
		else
			k = k + 1
		end
	end
	return groups
end

-- "learned" if any number scales, "flat" if numbers held still while stats moved, else "learning".
function ns.TrackStatus(track, template)
	local anyFlat = false
	for _, fit in ipairs(ns.GetFits(track, template)) do
		if fit.kind == "linear" then
			return "learned"
		elseif fit.kind == "flat" then
			anyFlat = true
		end
	end
	return anyFlat and "flat" or "learning"
end

-------------------------------------------------------------------------------
-- Sampling
-------------------------------------------------------------------------------

local function InCombat()
	return InCombatLockdown() or UnitAffectingCombat("player")
end

local function SpellbookSpellIDs()
	local ids = {}
	local bank = Enum.SpellBookSpellBank.Player
	local SPELL, FUTURE = Enum.SpellBookItemType.Spell, Enum.SpellBookItemType.FutureSpell
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if info and not info.shouldHide then
			for slot = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
				local item = C_SpellBook.GetSpellBookItemInfo(slot, bank)
				if item and item.spellID and not item.isOffSpec and (item.itemType == SPELL or item.itemType == FUTURE) then
					ids[#ids + 1] = item.spellID
				end
			end
		end
	end
	return ids
end

-- Every talent's spell, taken or not, so an untaken talent's scaling shows up before you
-- commit points to it. Returns { [spellID] = taken }.
local function TalentSpells()
	local spells = {}
	local configID = C_ClassTalents and C_ClassTalents.GetActiveConfigID()
	local config = configID and C_Traits.GetConfigInfo(configID)
	if not config then
		return spells
	end
	for _, treeID in ipairs(config.treeIDs) do
		for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
			local node = C_Traits.GetNodeInfo(configID, nodeID)
			if node and node.isVisible then
				for _, entryID in ipairs(node.entryIDs) do
					local entry = C_Traits.GetEntryInfo(configID, entryID)
					local definition = entry and entry.definitionID and C_Traits.GetDefinitionInfo(entry.definitionID)
					if definition and definition.spellID then
						-- choice nodes hold several entries; only the chosen one is taken
						local taken = node.ranksPurchased > 0 and (#node.entryIDs == 1
							or (node.activeEntry ~= nil and node.activeEntry.entryID == entryID))
						spells[definition.spellID] = spells[definition.spellID] or taken
					end
				end
			end
		end
	end
	return spells
end

ns.statsDirty = true

-- Reads one spell's text under snapshot sid. Repeats are ignored.
local function Observe(spellID, sid)
	local text = C_Spell.GetSpellDescription(spellID)
	if not text or issecret(text) then
		return false
	end
	if text == "" then
		C_Spell.RequestLoadSpellData(spellID) -- SPELL_TEXT_UPDATE brings us back
		return false
	end
	return ns.Record(spellID, text, sid)
end

-- Reads one spell between sweeps (tooltips, text updates). The stats are read again rather than
-- trusting the last sweep, so a stat change that no event announced can't pair new text with
-- old stats; it schedules a sweep instead.
local checkedAt
function ns.ObserveNow(spellID)
	if not ns.char or not ns.currentSnap or ns.statsDirty or InCombat() then
		return false
	end
	if checkedAt ~= GetTime() then -- once per frame is enough
		local stats = ns.ReadStats()
		if not stats then
			return false
		end
		if ns.InternSnapshot(stats) ~= ns.currentSnap then
			ns.RequestSweep()
			return false
		end
		checkedAt = GetTime()
	end
	return Observe(spellID, ns.currentSnap)
end

function ns.Sweep()
	if not ns.char then
		return
	end
	if InCombat() then
		ns.sweepAfterCombat = true
		return
	end
	local stats = ns.ReadStats()
	if not stats then
		return
	end
	ns.currentSnap = ns.InternSnapshot(stats)
	ns.statsDirty = false
	local changed = false
	local ids, inBook = SpellbookSpellIDs(), {}
	for _, spellID in ipairs(ids) do
		inBook[spellID] = true
	end
	-- pcall: the talent API is the part of this most likely to shift between beta builds
	local ok, talents = pcall(TalentSpells)
	if not ok then
		talents = {}
	end
	for spellID in pairs(talents) do
		if not inBook[spellID] then
			ids[#ids + 1] = spellID
		end
	end
	for _, spellID in ipairs(ids) do
		if Observe(spellID, ns.currentSnap) then
			changed = true
		end
		local spell = ns.char.spells[spellID]
		local taken = talents[spellID]
		local talent = taken ~= nil and (taken and "taken" or "untaken") or nil
		if spell and spell.talent ~= talent then
			spell.talent = talent
			changed = true
		end
	end
	if changed and ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

local sweepTimer
function ns.RequestSweep(delay)
	ns.statsDirty = true
	if sweepTimer then
		sweepTimer:Cancel()
	end
	sweepTimer = C_Timer.NewTimer(delay or SETTLE, function()
		sweepTimer = nil
		ns.Sweep()
	end)
end

-------------------------------------------------------------------------------
-- Saved data
-------------------------------------------------------------------------------

local function InitDB()
	SpellScaleDB = SpellScaleDB or {}
	for key, value in pairs(DEFAULTS) do
		if SpellScaleDB[key] == nil then
			SpellScaleDB[key] = value
		end
	end
	ns.settings = SpellScaleDB

	if not SpellScaleCharDB or SpellScaleCharDB.version ~= DB_VERSION then
		SpellScaleCharDB = { version = DB_VERSION, snaps = {}, nextSnap = 1, spells = {} }
	end
	ns.char = SpellScaleCharDB
	wipe(snapIndex)
	for id, s in pairs(ns.char.snaps) do
		snapIndex[SnapshotKey(s)] = id
	end
end

-- Drops snapshots no observation points at any more.
local function CollectSnapshots()
	local used = {}
	for _, spell in pairs(ns.char.spells) do
		for _, track in pairs(spell.tracks) do
			for _, o in ipairs(track.obs) do
				used[o.s] = true
			end
		end
	end
	for id in pairs(ns.char.snaps) do
		if not used[id] then
			ns.char.snaps[id] = nil
		end
	end
end

function ns.Reset()
	SpellScaleCharDB = nil
	InitDB()
	wipe(fitCache)
	ns.currentSnap = nil
	ns.RequestSweep(0.1)
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= addonName then
		return
	end
	frame:UnregisterEvent("ADDON_LOADED")
	InitDB()
end

function handlers.PLAYER_ENTERING_WORLD()
	ns.RequestSweep(2)
end

function handlers.PLAYER_REGEN_ENABLED()
	if ns.sweepAfterCombat then
		ns.sweepAfterCombat = false
		ns.RequestSweep(1)
	end
end

function handlers.SPELL_TEXT_UPDATE(spellID)
	if spellID and ns.ObserveNow(spellID) and ns.OnDataChanged then
		ns.OnDataChanged()
	end
end

function handlers.PLAYER_LOGOUT()
	CollectSnapshots()
end

-- Anything that can move a stat or rewrite a description
local STAT_EVENTS = {
	"PLAYER_EQUIPMENT_CHANGED", "UNIT_STATS", "UNIT_AURA", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER",
	"UNIT_DAMAGE", "SPELL_POWER_CHANGED", "PLAYER_DAMAGE_DONE_MODS", "COMBAT_RATING_UPDATE", "PLAYER_LEVEL_UP",
	"SPELLS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED",
	"UPDATE_SHAPESHIFT_FORM", "UNIT_INVENTORY_CHANGED",
}
local UNIT_EVENTS = {
	UNIT_STATS = true, UNIT_AURA = true, UNIT_ATTACK_POWER = true, UNIT_RANGED_ATTACK_POWER = true, UNIT_DAMAGE = true,
	UNIT_INVENTORY_CHANGED = true,
}

local function OnStatEvent()
	ns.RequestSweep()
end

for _, event in ipairs(STAT_EVENTS) do
	handlers[event] = OnStatEvent
end

frame:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)
for event in pairs(handlers) do
	-- pcall: an event Blizzard renames in a later build shouldn't take the addon down with it
	if UNIT_EVENTS[event] then
		pcall(frame.RegisterUnitEvent, frame, event, "player")
	else
		pcall(frame.RegisterEvent, frame, event)
	end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function Print(...)
	print("|cff7fc8ffSpellScale|r:", ...)
end
ns.Print = Print

local function FindSpell(query)
	local id = tonumber(query)
	if id then
		return ns.char.spells[id] and id
	end
	query = lower(query)
	for spellID, spell in pairs(ns.char.spells) do
		if spell.name and lower(spell.name) == query then
			return spellID
		end
	end
end

-- Dumps what the solver thinks of one spell, for checking its work in game.
local function Explain(query)
	local spellID = FindSpell(query)
	if not spellID then
		Print("no data for", query)
		return
	end
	local spell = ns.char.spells[spellID]
	Print(format("%s %s (%d)%s", spell.name or "?", spell.rank or "", spellID,
		spell.talent and (" talent, " .. (spell.talent == "taken" and "taken" or "not taken")) or ""))
	for template, track in pairs(spell.tracks) do
		print(format("  %s%s  [%d obs]", template == spell.cur and "* " or "", template, #track.obs))
		for slot, fit in ipairs(ns.GetFits(track, template)) do
			local line
			if fit.kind == "linear" then
				line = format("base %s + %s  (n=%d%s)", ns.FormatNumber(fit.a), ns.FormatFit(fit), fit.n,
					fit.rivals and ", also fits: " .. concat(fit.rivals, ", ") or "")
			elseif fit.kind == "flat" then
				line = "flat at " .. ns.FormatNumber(fit.value)
			else
				line = "no stat has moved yet"
			end
			print(format("    #%d: %s", slot, line))
		end
	end
end

SLASH_SPELLSCALE1 = "/spellscale"
SLASH_SPELLSCALE2 = "/ss"
SlashCmdList.SPELLSCALE = function(msg)
	local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = lower(cmd)
	if cmd == "" then
		ns.ToggleWindow()
	elseif cmd == "scan" then
		ns.RequestSweep(0)
		Print("sampling your spellbook")
	elseif cmd == "tooltips" or cmd == "hints" then
		ns.settings[cmd] = not ns.settings[cmd]
		Print(cmd, ns.settings[cmd] and "on" or "off")
	elseif cmd == "spell" and rest ~= "" then
		Explain(rest)
	elseif cmd == "reset" then
		if rest == "confirm" then
			ns.Reset()
			Print("forgot everything this character learned")
		else
			Print("this forgets everything this character learned; type /ss reset confirm")
		end
	else
		Print("/ss: window · /ss scan · /ss spell <name or id> · /ss tooltips · /ss hints · /ss reset")
	end
end

function SpellScale_OnAddonCompartmentClick()
	ns.ToggleWindow()
end
