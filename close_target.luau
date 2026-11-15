local M = {}

local function list(value)
	return if type(value) == "table" then value else {}
end

local function owned(panes, pane)
	return type(panes) == "table" and panes[pane] == true
end

-- Buckets items by their `key` field, keeping list order; nil keys are skipped.
local function group(items, key)
	local out = {}
	for _, item in items do
		local k = item[key]
		if k ~= nil then
			out[k] = out[k] or {}
			table.insert(out[k], item)
		end
	end
	return out
end

local function index_state(panes, hosts)
	local pane_by_id, pane_order = {}, {}
	for _, pane in list(panes) do
		if type(pane) == "table" and type(pane.pane) == "number" then
			pane_by_id[pane.pane] = pane
			table.insert(pane_order, pane)
		end
	end
	local host_by_pane, host_by_session, host_by_id = {}, {}, {}
	for _, host in list(hosts) do
		if type(host) == "table" then
			if host.id ~= nil then host_by_id[host.id] = host end
			for _, pane in list(host.panes) do if pane ~= nil then host_by_pane[pane] = host end end
			for _, session in list(host.sessions) do if session ~= nil then host_by_session[session] = host end end
		end
	end
	return pane_by_id, pane_order, host_by_pane, host_by_session, host_by_id
end

local function connected(host)
	return not host or host.state == nil or host.state == "connected"
end

local function target_in_tab(tab, pane_by_id, panes_of, closed_tab, owned_panes)
	if not tab or tab.id == closed_tab then return nil end
	local focused = pane_by_id[tab.pane]
	if focused and focused.tab == tab.id and not owned(owned_panes, focused.pane) then
		return focused.pane
	end
	for _, pane in panes_of[tab.id] or {} do
		if not owned(owned_panes, pane.pane) then return pane.pane end
	end
	return nil
end

local function default_target(session, tabs_by_id, tabs_of, pane_by_id, panes_of, closed_tab, owned_panes)
	local seen = {}
	for _, id in list(session.tabs) do
		seen[id] = true
		local tab = tabs_by_id[id]
		if tab and tab.session == session.id then
			local pane = target_in_tab(tab, pane_by_id, panes_of, closed_tab, owned_panes)
			if pane then return pane end
		end
	end
	for _, tab in tabs_of[session.id] or {} do
		if not seen[tab.id] and tab.id ~= closed_tab then
			local info = tabs_by_id[tab.id]
			local pane = target_in_tab(info, pane_by_id, panes_of, closed_tab, owned_panes)
			if pane then return pane end
		end
	end
	return nil
end

function M.select(agents, panes, tabs, sessions, closed_tab, owned_panes, hosts, current_host)
	local pane_by_id, pane_order, host_by_pane, host_by_session, host_by_id = index_state(panes, hosts)
	for _, agent in list(agents) do
		if type(agent) == "table" and agent.state ~= "exited" and type(agent.pane) == "number"
			and not owned(owned_panes, agent.pane) then
			local pane = pane_by_id[agent.pane]
			if pane and (closed_tab == nil or pane.tab ~= closed_tab) then
				local host = host_by_pane[agent.pane]
				if not host and type(agent.host) == "table" then
					host = host_by_id[agent.host.id] or agent.host
				elseif not host and type(agent.host) == "number" then
					host = host_by_id[agent.host]
				end
				if connected(host) then return agent.pane end
			end
		end
	end

	local tabs_by_id, tabs_order = {}, {}
	for _, tab in list(tabs) do
		if type(tab) == "table" and type(tab.id) == "number" then
			tabs_by_id[tab.id] = tab
			table.insert(tabs_order, tab)
		end
	end
	local tabs_of, panes_of = group(tabs_order, "session"), group(pane_order, "tab")
	local other_host
	for _, session in list(sessions) do
		if type(session) == "table" and session.name == "Default" then
			local host = host_by_session[session.id]
			local host_id = host and host.id
			if not host and session.host ~= nil then
				host_id = if type(session.host) == "table" then session.host.id else session.host
				host = host_by_id[host_id]
			end
			if not host_id and session.current then host_id = current_host end
			if connected(host) then
				local pane = default_target(session, tabs_by_id, tabs_of, pane_by_id, panes_of, closed_tab, owned_panes)
				if pane then
					if host_id == current_host then return pane end
					if not other_host then other_host = pane end
				end
			end
		end
	end
	return other_host
end

return M
