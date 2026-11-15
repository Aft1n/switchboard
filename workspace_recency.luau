-- Orders workspaces by when they were last launched into or worked in (kv `workspace_recency`,
-- id -> ms). Workspaces touched within 24 h come first, newest first; the rest keep Tern's order.
local M = {}
local DAY = 24 * 60 * 60 * 1000

function M.key(id) return string.format("%.0f", id) end

function M.sort(projects, stamps, now)
	local order = {}
	for i, project in projects do order[project] = i end
	local function recent(project)
		local at = stamps[M.key(project.id)]
		return if at and now - at < DAY then at else nil
	end
	table.sort(projects, function(a, b)
		local ra, rb = recent(a), recent(b)
		if (ra ~= nil) ~= (rb ~= nil) then return ra ~= nil end
		if ra and ra ~= rb then return ra > rb end
		return order[a] < order[b]
	end)
end

return M
