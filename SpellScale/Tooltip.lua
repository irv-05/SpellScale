local _, ns = ...

-- Writes the learned coefficients into spell tooltips: "causes 87 to 104 (42.9% SP) Fire damage".
-- A tooltip line is matched to learned data by its template, so annotations land on the right
-- numbers no matter what the current values are.

local Parse = ns.Parse

local issecret = issecretvalue or function()
	return false
end

local COLOR_SURE = "|cff7fc8ff"
local COLOR_GUESS = "|cffd9b860"
local COLOR_HINT = "|cff808080"

local function Annotation(fit)
	return " " .. (fit.rivals and COLOR_GUESS or COLOR_SURE) .. "(" .. ns.FormatFit(fit) .. ")|r"
end

-- Returns text with annotations spliced in, or nil if the line isn't a learned description.
local function AnnotateLine(spell, text)
	if not text or issecret(text) or not text:find("%d") then
		return nil
	end
	local template, nums = Parse.Scan(text)
	local track = spell.tracks[template]
	if not track then
		return nil
	end
	local inserts = {}
	for _, group in ipairs(ns.Groups(track, template)) do
		inserts[group.last] = Annotation(group.fit)
	end
	if not next(inserts) then
		return text, track, template
	end
	return Parse.Splice(text, nums, inserts), track, template
end

local function OnSpellTooltip(tooltip, data)
	if not ns.settings or not ns.settings.tooltips or not data then
		return
	end
	local spellID = data.id
	local name = tooltip:GetName()
	if not spellID or issecret(spellID) or not name then
		return
	end
	-- Only trust the id if the tooltip is titled with that spell's name. Some tooltips (the
	-- talent tree's, possibly) may carry a different kind of id, which would point at an
	-- unrelated spell.
	local title = _G[name .. "TextLeft1"] and _G[name .. "TextLeft1"]:GetText()
	local spellName = C_Spell.GetSpellName(spellID)
	if not title or issecret(title) or not spellName or not title:find(spellName, 1, true) then
		return
	end
	if ns.ObserveNow(spellID) and ns.OnDataChanged then
		ns.OnDataChanged()
	end
	local spell = ns.char.spells[spellID]
	if not spell then
		return
	end

	local matched, changed = nil, false
	for i = 1, tooltip:NumLines() do
		local line = _G[name .. "TextLeft" .. i]
		local text = line and line:GetText()
		local newText, track, template = AnnotateLine(spell, text)
		if newText then
			matched = matched or { track = track, template = template }
			if newText ~= text then
				line:SetText(newText)
				changed = true
			end
		end
	end

	local template = matched and matched.template or spell.cur
	local track = template and spell.tracks[template]
	if track then
		local status = ns.TrackStatus(track, template)
		if status == "learning" and ns.settings.hints then
			tooltip:AddLine(COLOR_HINT .. "SpellScale: still learning (needs a stat change)|r")
			changed = true
		elseif status == "learned" and not matched then
			-- Description wasn't found verbatim in the tooltip; list the results underneath.
			local values = track.obs[#track.obs].v
			for _, group in ipairs(ns.Groups(track, template)) do
				local now = ns.FormatNumber(values[group.first])
				if group.last ~= group.first then
					now = now .. "-" .. ns.FormatNumber(values[group.last])
				end
				tooltip:AddLine(now .. " " .. group.context .. Annotation(group.fit), 1, 1, 1)
			end
			changed = true
		end
	end

	if changed then
		tooltip:Show()
	end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpellTooltip)
