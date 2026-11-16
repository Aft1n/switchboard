-- Local tree edits the sidebar block can apply without a round trip through the window:
-- a disclosure flip and the selection highlight. Both are presentation only; the window
-- remains authoritative and its next pushed tree overwrites them.
local M = {}

local OPEN = "cp-subagent-open"
local SELECTED_AGENT = "cp-agent-selected"
local SELECTED_TAB = "cp-selected"

-- Removes a class with a plain splice: these names contain hyphens, which are Lua pattern
-- quantifiers, so string.gsub with the bare name would never match.
local function unclass(class, name)
	local from, to = string.find(class, name, 1, true)
	if not from then return class end
	return string.gsub(string.sub(class, 1, from - 1), "%s+$", "") .. string.sub(class, to + 1)
end

local function addclass(class, name)
	if string.find(class, name, 1, true) then return class end
	return class .. " " .. name
end

-- Flips the keyed disclosure button's open class and aria-expanded in a pushed tree.
function M.toggle_disclosure(node, key): boolean
	if type(node) ~= "table" then return false end
	local p = node.p
	if type(p) == "table" and p.key == key then
		local class = p.class or ""
		local open = string.find(class, OPEN, 1, true) ~= nil
		p.class = if open then unclass(class, OPEN) else addclass(class, OPEN)
		if type(p.attrs) == "table" then p.attrs["aria-expanded"] = if open then "false" else "true" end
		return true
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			if M.toggle_disclosure(child, key) then return true end
		end
	end
	return false
end

-- Moves the selection highlight to `pane` (an agent card, its workspace tab row, or a subagent
-- child of it) in place, so a click looks instant while the click travels to the window.
function M.select_card(node, pane): boolean
	if type(node) ~= "table" then return false end
	local target = tostring(pane)
	local p = node.p
	local click = type(p) == "table" and type(p.actions) == "table" and p.actions.click or nil
	local own = nil
	if type(click) == "string" then
		own = string.match(click, "^pane:(%d+)$") or string.match(click, "^subagent:(%d+):")
	end
	local changed = false
	if own ~= nil and string.find(p.class or "", "cp-agent", 1, true) then
		local class = p.class or ""
		if own == target then
			if not string.find(class, SELECTED_AGENT, 1, true) then p.class = addclass(class, SELECTED_AGENT); changed = true end
		elseif string.find(class, SELECTED_AGENT, 1, true) then
			p.class = unclass(class, SELECTED_AGENT); changed = true
		end
		if type(p.attrs) == "table" then p.attrs["aria-pressed"] = if own == target then "true" else "false" end
	elseif own ~= nil and string.find(p.class or "", "cp-tab", 1, true) then
		local class = p.class or ""
		if own == target then
			if not string.find(class, SELECTED_TAB, 1, true) then p.class = addclass(class, SELECTED_TAB); changed = true end
		elseif string.find(class, SELECTED_TAB, 1, true) then
			p.class = unclass(class, SELECTED_TAB); changed = true
		end
		if type(p.attrs) == "table" then p.attrs["aria-pressed"] = if own == target then "true" else "false" end
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			if M.select_card(child, target) then changed = true end
		end
	end
	return changed
end

return M
