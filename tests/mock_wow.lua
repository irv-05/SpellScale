-- A small fake of the WoW client: just enough API for SpellScale to run outside the game.
-- The "game" is a player stat table plus spells whose descriptions are computed from it, the
-- same way Forever's live tooltips fold your stats into the numbers.

local M = {}

local floor = math.floor

M.player = {
	school = { 0, 0, 0, 0, 0, 0, 0 }, -- GetSpellBonusDamage by school index
	heal = 0,
	ap = 40,
	rap = 30,
	stats = { 30, 20, 25, 40, 45 }, -- str agi sta int spi
	wpnLo = 10,
	wpnHi = 15,
	lvl = 20,
	inCombat = false,
}
M.spells = {} -- [id] = { name, rank, desc = function(player) -> string }
M.book = {} -- spell ids in spellbook order

-- clock and timers ------------------------------------------------------------

M.now = 1000
function GetTime()
	return M.now
end
function time()
	return floor(M.now)
end

local timers = {}
C_Timer = {}
function C_Timer.NewTimer(delay, fn)
	local t = { at = M.now + delay, fn = fn }
	timers[#timers + 1] = t
	return {
		Cancel = function()
			t.cancelled = true
		end,
	}
end
function C_Timer.After(delay, fn)
	C_Timer.NewTimer(delay, fn)
end

-- Advances the clock, running timers as they come due.
function M.advance(seconds)
	M.now = M.now + seconds
	local ran = true
	while ran do
		ran = false
		for i, t in ipairs(timers) do
			if t.cancelled then
				table.remove(timers, i)
				ran = true
				break
			elseif t.at <= M.now then
				table.remove(timers, i)
				t.fn()
				ran = true
				break
			end
		end
	end
end

-- frames ----------------------------------------------------------------------

M.eventFrames = {}

local function noop() end

local Widget = {}
local function NewWidget(kind)
	local w = { _kind = kind, _shown = true, _scripts = {}, _events = {}, _text = "", _checked = false }
	return setmetatable(w, Widget)
end
Widget.__index = function(self, key)
	local method = rawget(Widget, key)
	if method then
		return method
	end
	return noop
end
function Widget:RegisterEvent(event)
	if event == "NOT_A_REAL_EVENT" then
		error("unknown event")
	end
	self._events = self._events or {}
	self._events[event] = true
	M.eventFrames[self] = true
end
function Widget:RegisterUnitEvent(event)
	Widget.RegisterEvent(self, event)
end
function Widget:UnregisterEvent(event)
	self._events[event] = nil
end
function Widget:SetScript(name, fn)
	self._scripts[name] = fn
end
function Widget:HookScript(name, fn)
	local old = self._scripts[name]
	self._scripts[name] = function(...)
		if old then
			old(...)
		end
		fn(...)
	end
end
function Widget:Show()
	local was = self._shown
	self._shown = true
	if not was and self._scripts.OnShow then
		self._scripts.OnShow(self)
	end
end
function Widget:Hide()
	self._shown = false
end
function Widget:SetShown(shown)
	if shown then
		self:Show()
	else
		self:Hide()
	end
end
function Widget:IsShown()
	return self._shown
end
function Widget:SetText(text)
	self._text = text
	if self._scripts.OnTextChanged then
		self._scripts.OnTextChanged(self)
	end
end
function Widget:GetText()
	return self._text
end
function Widget:GetStringHeight()
	return 12
end
function Widget:SetChecked(c)
	self._checked = c
end
function Widget:GetChecked()
	return self._checked
end
function Widget:CreateFontString()
	return NewWidget("FontString")
end
function Widget:CreateTexture()
	return NewWidget("Texture")
end
function Widget:GetName()
	return self._name
end

function CreateFrame(kind, name, parent, template)
	local w = NewWidget(kind)
	w._name = name
	if template == "BasicFrameTemplateWithInset" then
		w.TitleText = NewWidget("FontString")
	elseif template == "UICheckButtonTemplate" then
		w.Text = NewWidget("FontString")
	end
	if name then
		_G[name] = w
	end
	return w
end

function M.fire(event, ...)
	for f in pairs(M.eventFrames) do
		if f._events[event] and f._scripts.OnEvent then
			f._scripts.OnEvent(f, event, ...)
		end
	end
end

UIParent = NewWidget("Frame")
UISpecialFrames = {}
tinsert = table.insert
GameFontNormal, GameFontHighlightSmall, GameFontDisableSmall = {}, {}, {}
SlashCmdList = {}
function wipe(t)
	for k in pairs(t) do
		t[k] = nil
	end
	return t
end

-- tooltip ---------------------------------------------------------------------

Enum = {
	SpellBookSpellBank = { Player = 0, Pet = 1 },
	SpellBookItemType = { None = 0, Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 },
	TooltipDataType = { Item = 0, Spell = 1 },
}

M.postCalls = {}
TooltipDataProcessor = {}
function TooltipDataProcessor.AddTooltipPostCall(kind, fn)
	M.postCalls[kind] = fn
end

GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
GameTooltip._lines = 0
function GameTooltip:NumLines()
	return self._lines
end
function GameTooltip:AddLine(text)
	self._lines = self._lines + 1
	local line = _G["GameTooltipTextLeft" .. self._lines] or NewWidget("FontString")
	_G["GameTooltipTextLeft" .. self._lines] = line
	line._text = text
end
function GameTooltip:ClearLines()
	self._lines = 0
end

-- Builds the tooltip the way the client would, then runs the addon's post-call on it.
function M.showSpellTooltip(id, title)
	GameTooltip:ClearLines()
	local spell = M.spells[id]
	GameTooltip:AddLine(title or spell.name)
	GameTooltip:AddLine("1.5 sec cast")
	GameTooltip:AddLine(spell.desc(M.player))
	M.postCalls[Enum.TooltipDataType.Spell](GameTooltip, { id = id })
	local lines = {}
	for i = 1, GameTooltip:NumLines() do
		lines[i] = _G["GameTooltipTextLeft" .. i]:GetText()
	end
	return lines
end

-- game API ----------------------------------------------------------------------

C_Spell = {}
function C_Spell.GetSpellDescription(id)
	local spell = M.spells[id]
	return spell and spell.desc(M.player) or nil
end
function C_Spell.GetSpellName(id)
	return M.spells[id] and M.spells[id].name
end
function C_Spell.GetSpellSubtext(id)
	return M.spells[id] and M.spells[id].rank or ""
end
function C_Spell.GetSpellTexture(id)
	return 136000 + id
end
function C_Spell.RequestLoadSpellData() end

C_SpellBook = {}
function C_SpellBook.GetNumSpellBookSkillLines()
	return 1
end
function C_SpellBook.GetSpellBookSkillLineInfo()
	return { name = "General", itemIndexOffset = 0, numSpellBookItems = #M.book, shouldHide = false }
end
function C_SpellBook.GetSpellBookItemInfo(slot)
	local id = M.book[slot]
	return { spellID = id, actionID = id, itemType = Enum.SpellBookItemType.Spell, isPassive = false, isOffSpec = false }
end

function GetSpellBonusDamage(school)
	return M.player.school[school]
end
function GetSpellBonusHealing()
	return M.player.heal
end
function UnitAttackPower()
	return M.player.ap, 0, 0
end
function UnitRangedAttackPower()
	return M.player.rap, 0, 0
end
function UnitStat(_, i)
	return M.player.stats[i], M.player.stats[i], 0, 0
end
function UnitDamage()
	return M.player.wpnLo, M.player.wpnHi
end
function GetShieldBlock()
	return M.player.block or 0
end
function UnitLevel()
	return M.player.lvl
end
function InCombatLockdown()
	return M.player.inCombat
end
function UnitAffectingCombat()
	return M.player.inCombat
end

-- talent tree: M.talents[nodeID] = { entries = { spellID, ... }, ranks = n, active = spellID, hidden = bool }
-- Entry and definition ids are the spell id, to keep the fake small.
M.talents = {}
C_ClassTalents = {}
function C_ClassTalents.GetActiveConfigID()
	return next(M.talents) and 1 or nil
end
C_Traits = {}
function C_Traits.GetConfigInfo()
	return { ID = 1, treeIDs = { 1 } }
end
function C_Traits.GetTreeNodes()
	local ids = {}
	for nodeID in pairs(M.talents) do
		ids[#ids + 1] = nodeID
	end
	table.sort(ids)
	return ids
end
function C_Traits.GetNodeInfo(_, nodeID)
	local node = M.talents[nodeID]
	return {
		ID = nodeID,
		entryIDs = node.entries,
		isVisible = not node.hidden,
		ranksPurchased = node.ranks,
		activeRank = node.ranks,
		activeEntry = node.active and { entryID = node.active, rank = node.ranks } or nil,
	}
end
function C_Traits.GetEntryInfo(_, entryID)
	return { definitionID = entryID, maxRanks = 1 }
end
function C_Traits.GetDefinitionInfo(definitionID)
	return { spellID = definitionID }
end

-- loading -----------------------------------------------------------------------

M.ns = {}
function M.load(dir)
	for _, file in ipairs({ "Parse.lua", "Solver.lua", "Core.lua", "Tooltip.lua", "UI.lua" }) do
		local chunk = assert(loadfile(dir .. "/" .. file))
		chunk("SpellScale", M.ns)
	end
	M.fire("ADDON_LOADED", "SpellScale")
end

-- Changes stats like equipping gear would, then lets the addon's debounce run.
function M.change(fn)
	fn(M.player)
	M.fire("PLAYER_EQUIPMENT_CHANGED")
	M.fire("UNIT_STATS", "player")
	M.advance(1)
end

-- Adds to every spell school, like "+X spell damage" gear.
function M.addSpellDamage(p, n)
	for i = 2, 7 do
		p.school[i] = p.school[i] + n
	end
end

return M
