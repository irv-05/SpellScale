local _, ns = ...

-- The browser: every spell the addon has looked at, with what it has worked out so far.

local format, lower, concat = string.format, string.lower, table.concat

local WIDTH, HEIGHT = 500, 540
local CONTENT_WIDTH = WIDTH - 46
local STATUS_ORDER = { learned = 1, learning = 2, flat = 3 }
local TALENT_TAGS = { taken = "talent", untaken = "talent, not taken" } -- also searchable

local frame, content, search, summary
local fonts, textures, nFonts, nTextures = {}, {}, 0, 0
local showFlat = false

local function Font(fontObject)
	nFonts = nFonts + 1
	local fs = fonts[nFonts]
	if not fs then
		fs = content:CreateFontString(nil, "OVERLAY")
		fs:SetJustifyH("LEFT")
		fonts[nFonts] = fs
	end
	fs:SetFontObject(fontObject)
	fs:ClearAllPoints()
	fs:SetWidth(0)
	fs:Show()
	return fs
end

local function Icon(fileID)
	nTextures = nTextures + 1
	local tex = textures[nTextures]
	if not tex then
		tex = content:CreateTexture(nil, "ARTWORK")
		tex:SetSize(18, 18)
		tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		textures[nTextures] = tex
	end
	tex:SetTexture(fileID or 134400) -- question mark icon
	tex:ClearAllPoints()
	tex:Show()
	return tex
end

local function ReleaseAll()
	for i = 1, nFonts do
		fonts[i]:Hide()
	end
	for i = 1, nTextures do
		textures[i]:Hide()
	end
	nFonts, nTextures = 0, 0
end

local function RivalText(rivals)
	local names = {}
	for i, key in ipairs(rivals) do
		local parts = {}
		for part in key:gmatch("[^+]+") do
			parts[#parts + 1] = ns.STAT_BY_KEY[part].short
		end
		names[i] = concat(parts, "+")
	end
	return "could also be " .. concat(names, ", ")
end

-- "doesn't scale with SP (moved 87), AP (moved 30)": which stats were tried and how hard.
local function FlatText(track, template)
	local tested = {}
	for _, fit in ipairs(ns.GetFits(track, template)) do
		if fit.kind == "flat" then
			for family, range in pairs(fit.tested) do
				tested[family] = math.max(tested[family] or 0, range)
			end
		end
	end
	local parts, seen = {}, {}
	for _, stat in ipairs(ns.STATS) do
		if tested[stat.family] and not seen[stat.family] then
			seen[stat.family] = true
			parts[#parts + 1] = format("%s (moved %s)", stat.short, ns.FormatNumber(tested[stat.family]))
		end
	end
	return "|cff808080doesn't scale with " .. concat(parts, ", ") .. "|r"
end

local function Span(a, b, same)
	local text = ns.FormatNumber(a)
	if not same then
		text = text .. "-" .. ns.FormatNumber(b)
	end
	return text
end

-- One line per scaling number: "87-104 Fire damage = 14-23 + 42.9% SP"
local function GroupLine(track, template, group)
	local fits = ns.GetFits(track, template)
	local values = track.obs[#track.obs].v
	local single = group.first == group.last
	local now = Span(values[group.first], values[group.last], single)
	local base = Span(fits[group.first].a, fits[group.last].a, single)
	local fit = group.fit
	local text = format("|cffffffff%s|r %s  |cff808080=|r %s + %s%s|r", now, group.context, base,
		fit.rivals and "|cffd9b860" or "|cff7fc8ff", ns.FormatFit(fit))
	if fit.rivals then
		text = text .. "\n|cff808080" .. RivalText(fit.rivals) .. ": swap gear that changes only one|r"
	end
	return text
end

local function Entries()
	local query = lower(search:GetText() or "")
	local list = {}
	for spellID, spell in pairs(ns.char.spells) do
		local template = spell.cur
		local track = template and spell.tracks[template]
		local name = spell.name or ("Spell " .. spellID)
		local tag = TALENT_TAGS[spell.talent]
		if track and (query == "" or lower(name .. " " .. (tag or "")):find(query, 1, true)) then
			local status = ns.TrackStatus(track, template)
			if status ~= "flat" or showFlat then
				list[#list + 1] = { id = spellID, spell = spell, name = name, tag = tag, track = track, template = template, status = status }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.status ~= b.status then
			return STATUS_ORDER[a.status] < STATUS_ORDER[b.status]
		elseif a.name ~= b.name then
			return a.name < b.name
		end
		return (a.spell.rank or "") < (b.spell.rank or "")
	end)
	return list
end

local function Refresh()
	if not frame or not frame:IsShown() then
		return
	end
	ReleaseAll()
	local counts = { learned = 0, learning = 0, flat = 0 }
	for _, spell in pairs(ns.char.spells) do
		local track = spell.cur and spell.tracks[spell.cur]
		if track then
			local status = ns.TrackStatus(track, spell.cur)
			counts[status] = counts[status] + 1
		end
	end
	summary:SetText(format("%d scaling · %d learning · %d don't scale", counts.learned, counts.learning, counts.flat))

	local y = 4
	for _, entry in ipairs(Entries()) do
		Icon(entry.spell.icon):SetPoint("TOPLEFT", 4, -y)
		local title = Font(GameFontNormal)
		title:SetPoint("TOPLEFT", 28, -y - 3)
		local rank = entry.spell.rank
		title:SetText(entry.name .. (rank and rank ~= "" and ("  |cff808080" .. rank .. "|r") or "")
			.. (entry.tag and ("  " .. (entry.spell.talent == "untaken" and "|cffd9b860" or "|cff808080") .. entry.tag .. "|r") or ""))
		y = y + 22

		local groups = ns.Groups(entry.track, entry.template)
		local lines = {}
		for _, group in ipairs(groups) do
			lines[#lines + 1] = GroupLine(entry.track, entry.template, group)
		end
		if #groups == 0 then
			lines[1] = entry.status == "flat" and FlatText(entry.track, entry.template)
				or format("|cff808080learning: %d reading%s so far, needs a stat change|r", #entry.track.obs,
					#entry.track.obs == 1 and "" or "s")
		end
		for _, text in ipairs(lines) do
			local line = Font(GameFontHighlightSmall)
			line:SetPoint("TOPLEFT", 28, -y)
			line:SetWidth(CONTENT_WIDTH - 32)
			line:SetText(text)
			y = y + line:GetStringHeight() + 3
		end
		y = y + 8
	end
	content:SetHeight(math.max(y, 1))
end

local refreshPending = false
function ns.OnDataChanged()
	if refreshPending or not frame or not frame:IsShown() then
		return
	end
	refreshPending = true
	C_Timer.After(0.2, function()
		refreshPending = false
		Refresh()
	end)
end

local function Checkbox(label, x, get, set)
	local box = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	box:SetSize(22, 22)
	box:SetPoint("BOTTOMLEFT", x, 10)
	box.Text:SetText(label)
	box:SetChecked(get())
	box:SetScript("OnClick", function(self)
		set(self:GetChecked())
		Refresh()
	end)
	return box
end

local function Build()
	frame = CreateFrame("Frame", "SpellScaleFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetScript("OnShow", Refresh)
	frame.TitleText:SetText("SpellScale")
	tinsert(UISpecialFrames, "SpellScaleFrame") -- Escape closes it

	search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
	search:SetSize(180, 20)
	search:SetPoint("TOPLEFT", 18, -32)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", Refresh)

	summary = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	summary:SetPoint("TOPRIGHT", -16, -37)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -60)
	scroll:SetPoint("BOTTOMRIGHT", -32, 40)
	content = CreateFrame("Frame", nil, scroll)
	content:SetSize(CONTENT_WIDTH, 1)
	scroll:SetScrollChild(content)

	Checkbox("Tooltips", 14, function()
		return ns.settings.tooltips
	end, function(on)
		ns.settings.tooltips = on
	end)
	Checkbox("Learning hints", 104, function()
		return ns.settings.hints
	end, function(on)
		ns.settings.hints = on
	end)
	Checkbox("Show spells that don't scale", 224, function()
		return showFlat
	end, function(on)
		showFlat = on
	end)

	frame:Hide()
end

function ns.ToggleWindow()
	if not frame then
		Build()
	end
	frame:SetShown(not frame:IsShown())
end
