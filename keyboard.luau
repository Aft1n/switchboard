local M = {}

function M.panes(agents)
	local panes = {}
	if type(agents) ~= "table" then return panes end
	for _, agent in agents do
		if type(agent) == "table" and type(agent.pane) == "number" and agent.state ~= "exited" then
			table.insert(panes, agent.pane)
		end
	end
	return panes
end

local function step(agents, current, direction)
	local panes = M.panes(agents)
	local count = #panes
	if count == 0 then return nil end
	local index
	for i, pane in panes do
		if pane == current then index = i; break end
	end
	if not index then return if direction > 0 then panes[1] else panes[count] end
	return panes[(index - 1 + direction) % count + 1]
end

function M.next(agents, current)
	return step(agents, current, 1)
end

function M.previous(agents, current)
	return step(agents, current, -1)
end

function M.at(agents, index)
	if type(index) ~= "number" or index < 1 or index > 9 or index % 1 ~= 0 then return nil end
	return M.panes(agents)[index]
end

function M.chords(bindings, action)
	local found={}
	for chord,actions in bindings or {} do
		for _,candidate in actions do
			if candidate==action then table.insert(found,chord);break end
		end
	end
	table.sort(found)
	return found
end

return M
