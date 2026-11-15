-- Agents the sidebar has seen, kept across closes and reloads (kv `agent_history`).
-- Entries are {pane,name,project,cwd,model,at,session,host}, newest first; `at` is
-- first sight, `session` the durable omp session id and `host` the host display
-- name. `live` is set by update and is not part of the identity: a reused pane
-- must not revive the previous agent's record.
local M = {}
local CAP = 50
local FIELDS = {"project","cwd","model"}
local SHELLS = {zsh=true,bash=true,fish=true,sh=true,pwsh=true,cmd=true}

-- Folder paths, prompts and shell names are not agent names worth keeping.
function M.is_placeholder(name, cwd, project)
	if type(name) ~= "string" or name == "" then return true end
	if string.find(name, "\n", 1, true) then return true end
	local first = string.sub(name, 1, 1)
	if first == "/" or first == "~" or first == "'" or first == '"' or first == "`" then return true end
	if SHELLS[name] or name == "omp" or name == "agent" or name == "shell" then return true end
	if project and name == project then return true end
	if type(cwd) == "string" and cwd ~= "" then
		if name == cwd or name == (string.match(cwd, "([^/]+)/*$") or "") then return true end
	end
	-- `user@host:~/dir` shell prompt
	return string.match(name, "%w@%w[%w%-%.]*:") ~= nil
end

-- Records live agents and refreshes their labels. `sessions` maps pane strings to
-- {session=...,cwd=...} from tern inspect. Returns true when `list` changed.
function M.update(list, agents, now, sessions)
	local changed = false
	for _,entry in list do entry.live = false end
	local function session_of(agent)
		local mapping = sessions and sessions[tostring(agent.pane)]
		-- A mapping for a reused pane describes that pane only while its cwd holds.
		if not mapping or not mapping.session or (mapping.cwd or "") ~= (agent.cwd or "") then return nil end
		return mapping.session
	end
	-- Session is the stable identity; oldest sight of it is canonical and duplicates merge.
	-- Without one, pane+cwd identifies the agent (a reused pane with a new cwd is new).
	local function match(agent, session)
		if session then
			local canonical
			for _,entry in list do
				if entry.session == session and (not canonical or (entry.at or 0) < (canonical.at or 0)) then canonical = entry end
			end
			if canonical then
				for index = #list, 1, -1 do
					if list[index].session == session and list[index] ~= canonical then table.remove(list, index); changed = true end
				end
				return canonical
			end
		end
		local cwd = agent.cwd or ""
		for _,entry in list do
			if entry.pane == agent.pane and (entry.cwd or "") == cwd then
				if session and entry.session and entry.session ~= session then return nil end
				return entry
			end
		end
		return nil
	end
	for _,agent in agents do
		local session = session_of(agent)
		local entry = match(agent, session)
		if not entry then
			entry = {pane=agent.pane, at=now}
			table.insert(list, 1, entry)
			changed = true
		end
		entry.live = true
		if session and entry.session ~= session then entry.session = session; changed = true end
		if entry.pane ~= agent.pane then entry.pane = agent.pane; changed = true end
		local name = agent.name
		if M.is_placeholder(name, agent.cwd, agent.project) then
			-- Keep the last real label; only a real live name may replace it.
			if entry.name and not M.is_placeholder(entry.name, entry.cwd, entry.project) then
				agent.name = entry.name
				name = entry.name
			else
				name = nil
			end
		end
		if name and entry.name ~= name then entry.name = name; changed = true end
		-- Host display name only: display metadata, never identity (and kept when the
		-- live agent reports none, e.g. a pane moving between hosts).
		if agent.host and agent.host.name and entry.host ~= agent.host.name then entry.host = agent.host.name; changed = true end
		for _,field in FIELDS do
			if entry[field] ~= agent[field] then entry[field] = agent[field]; changed = true end
		end
	end
	for index = #list, 1, -1 do
		local entry = list[index]
		if not entry.live and (entry.name == nil or M.is_placeholder(entry.name, entry.cwd, entry.project)) then
			table.remove(list, index)
			changed = true
		end
	end
	while #list > CAP do table.remove(list); changed = true end
	return changed
end

-- Recorded agents that are no longer live (by update's `live` flag, not pane reuse).
function M.closed(list)
	local out = {}
	for _,entry in list do
		if not entry.live and entry.name and not M.is_placeholder(entry.name, entry.cwd, entry.project) then
			table.insert(out, entry)
		end
	end
	return out
end

return M
