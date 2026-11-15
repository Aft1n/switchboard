-- The user's workspace order (kv `workspace_order`: ids in display order).
-- Tern has no pointer drag, so the list is reordered by lift-and-drop.
local recency = require("./workspace_recency")
local M = {}

local function key(id)
	return if type(id) == "string" then id else recency.key(id)
end

function M.ids(projects)
	local ids = {}
	for _, project in projects do table.insert(ids, key(project.id)) end
	return ids
end

-- Saved workspaces come first in their saved order; workspaces added since the
-- last drag follow in the order they were given.
function M.sort(projects, saved)
	if type(saved) ~= "table" or #saved == 0 then return end
	local rank, base = {}, {}
	for i, id in saved do rank[key(id)] = i end
	for i, project in projects do base[project] = i end
	table.sort(projects, function(a, b)
		local ra, rb = rank[key(a.id)], rank[key(b.id)]
		if ra and rb then return ra < rb end
		if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
		return base[a] < base[b]
	end)
end

-- Puts `from_id` above `to_id`; nil when either is gone or unchanged.
function M.move(order, from_id, to_id)
	local from, to = table.find(order, from_id), table.find(order, to_id)
	if not from or not to or from == to then return nil end
	local moved = table.remove(order, from)
	if from < to then to = to - 1 end
	table.insert(order, to, moved)
	return order
end

return M
