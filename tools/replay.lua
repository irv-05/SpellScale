-- Replays a character's saved SpellScale data through the solver, outside the game. For each
-- spell it prints every reading (only the stats that moved), and what the solver concluded.
--
-- usage: lua5.1 tools/replay.lua <WTF\...\SavedVariables\SpellScale.lua> [spell name or id]
--
-- The per-character file lives at
-- WTF\Account\<account>\<realm>\<character>\SavedVariables\SpellScale.lua

package.path = "tests/?.lua;" .. package.path
local path, query = arg[1], arg[2]
assert(path, "usage: lua5.1 tools/replay.lua <SpellScale.lua> [spell]")

-- SavedVariables files are plain Lua assignments; load it before the addon so the addon
-- picks it up on ADDON_LOADED like it would in game.
assert(loadfile(path))()
assert(SpellScaleCharDB, "no SpellScaleCharDB in " .. path .. " (is this the per-character file?)")

local M = require("mock_wow")
M.load("SpellScale")
local ns = M.ns
local format, concat = string.format, table.concat

local function matches(spellID, spell)
	if not query then
		return true
	end
	return tostring(spellID) == query or (spell.name and spell.name:lower():find(query:lower(), 1, true))
end

local ids = {}
for spellID, spell in pairs(ns.char.spells) do
	if matches(spellID, spell) then
		ids[#ids + 1] = spellID
	end
end
table.sort(ids, function(a, b)
	return (ns.char.spells[a].name or "") < (ns.char.spells[b].name or "")
end)

for _, spellID in ipairs(ids) do
	local spell = ns.char.spells[spellID]
	print(format("\n%s %s (%d)%s", spell.name or "?", spell.rank or "", spellID,
		spell.talent and ("  [talent, " .. spell.talent .. "]") or ""))
	for template, track in pairs(spell.tracks) do
		print(format("  %s%s", template == spell.cur and "* " or "  ", template))

		-- the stats that differ between this description's readings
		local moved = {}
		for _, stat in ipairs(ns.STATS) do
			local first
			for _, o in ipairs(track.obs) do
				local x = (ns.char.snaps[o.s] or {})[stat.key]
				if first == nil then
					first = x
				elseif x ~= first then
					moved[#moved + 1] = stat.key
					break
				end
			end
		end
		local header = {}
		for i, key in ipairs(moved) do
			header[i] = format("%6s", key)
		end
		print("      snap" .. concat(header) .. "  | values")
		for _, o in ipairs(track.obs) do
			local s = ns.char.snaps[o.s] or {}
			local cells = {}
			for i, key in ipairs(moved) do
				cells[i] = format("%6s", ns.FormatNumber(s[key] or 0))
			end
			local values = {}
			for i, v in ipairs(o.v) do
				values[i] = ns.FormatNumber(v)
			end
			print(format("      %4d%s  | %s", o.s, concat(cells), concat(values, " ")))
		end

		for slot, fit in ipairs(ns.GetFits(track, template)) do
			local line
			if fit.kind == "linear" then
				line = format("base %s + %s  (n=%d, ±%.1f%%%s%s)", ns.FormatNumber(fit.a), ns.FormatFit(fit), fit.n,
					fit.err * 100, fit.levelSteps and ", base rises with level" or "",
					fit.rivals and ", also fits: " .. concat(fit.rivals, ", ") or "")
			elseif fit.kind == "flat" then
				line = "flat at " .. ns.FormatNumber(fit.value)
			else
				line = "unknown"
			end
			print(format("      #%d %s", slot, line))
		end
	end
end
