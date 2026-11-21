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
	local was_live = {}
	for _,entry in list do was_live[entry] = entry.live == true; entry.live = false end
	local function session_of(agent)
		local mapping = sessions and sessions[tostring(agent.pane)]
		-- A mapping for a reused pane describes that pane only while its cwd holds.
		if not mapping or not mapping.session or (mapping.cwd or "") ~= (agent.cwd or "") then return nil end
		return mapping.session
	end
	-- A pin belongs to the agent, not to one of its records: merging keeps it, with its earliest time.
	local function take_pin(keep, drop)
		if not drop.pinned then return end
		if not keep.pinned then keep.pinned = true; keep.pinned_at = drop.pinned_at
		elseif (drop.pinned_at or 0) < (keep.pinned_at or 0) then keep.pinned_at = drop.pinned_at end
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
					if list[index].session == session and list[index] ~= canonical then
						take_pin(canonical, list[index])
						table.remove(list, index); changed = true
					end
				end
				return canonical
			end
		end
		local cwd = agent.cwd or ""
		for _,entry in list do
			-- Tern reuses pane ids: a closed entry on the same pane+cwd is another agent's record, not this one's.
			if was_live[entry] and entry.pane == agent.pane and (entry.cwd or "") == cwd then
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
		if not entry.live and not entry.pinned and (entry.name == nil or M.is_placeholder(entry.name, entry.cwd, entry.project)) then
			table.remove(list, index)
			changed = true
		end
	end
	-- Merge `drop` into `keep` (a live record must stay live, on its current pane).
	local function absorb(keep, drop)
		if drop.live then keep.live = true; keep.pane = drop.pane end
		if not keep.name and drop.name then keep.name = drop.name end
		take_pin(keep, drop)
	end
	-- Closed entries never reach `match`, so a session recorded twice (a resume under a new pane) merges here:
	-- the oldest sight stays, as in `match`.
	local kept = {}
	for index = #list, 1, -1 do
		local session = list[index].session
		if session then
			local keeper = kept[session]
			if keeper then
				if (list[index].at or 0) < (keeper.entry.at or 0) then
					absorb(list[index], keeper.entry)
					table.remove(list, keeper.index)
					kept[session] = {entry=list[index], index=index}
				else
					absorb(keeper.entry, list[index])
					table.remove(list, index)
				end
				changed = true
			else
				kept[session] = {entry=list[index], index=index}
			end
		end
	end
	-- A record made before the session was known (a resumed or restored pane inspects a few seconds late) is the
	-- same agent as the session record with that name in that folder: without this the session shows twice, live and closed.
	local function twin_key(entry)
		if not entry.name then return nil end
		return entry.name .. "\0" .. string.lower((string.gsub(entry.cwd or "", "/+$", "")))
	end
	local by_twin = {}
	for _,entry in list do
		local key = entry.session and twin_key(entry)
		if key and not by_twin[key] then by_twin[key] = entry end
	end
	for index = #list, 1, -1 do
		local entry = list[index]
		local key = not entry.session and twin_key(entry)
		local twin = key and by_twin[key]
		if twin then
			absorb(twin, entry)
			table.remove(list, index)
			changed = true
		end
	end
	-- Over cap, the oldest unpinned records go; pins are never evicted (all pinned leaves
	-- history over cap, bounded by however many the user pinned).
	if #list > CAP then
		local unpinned = {}
		for index, entry in list do if not entry.pinned then table.insert(unpinned, index) end end
		for index = #unpinned, 1, -1 do
			if #list <= CAP then break end
			table.remove(list, unpinned[index])
			changed = true
		end
	end
	return changed
end

-- Recorded agents that are no longer live (by update's `live` flag, not pane reuse).
-- Pinned entries live in the pinned strip instead of the Closed list.
function M.closed(list)
	local out = {}
	for _,entry in list do
		if not entry.live and not entry.pinned and entry.name and not M.is_placeholder(entry.name, entry.cwd, entry.project) then
			table.insert(out, entry)
		end
	end
	return out
end

-- Pinned entries, oldest pin first (falling back to first sight), then by pane.
function M.pinned(list)
	local out = {}
	for _,entry in list do if entry.pinned then table.insert(out, entry) end end
	table.sort(out, function(a,b)
		local aa, bb = a.pinned_at or a.at or 0, b.pinned_at or b.at or 0
		if aa ~= bb then return aa < bb end
		return tostring(a.pane or "") < tostring(b.pane or "")
	end)
	return out
end

return M
