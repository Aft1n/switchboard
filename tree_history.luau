-- A durable record of the workspaces and agent tabs Switchboard has seen, so a Tern daemon reset
-- (or a wiped session list) can be inspected and rebuilt after relaunch. Identity is the folder for
-- a project and the omp session id for an agent tab; titles are only labels.
local M = {}

local MAX_PROJECTS = 50
local MAX_TABS = 50
local MAX_RESTORE_TABS = 12

local function norm(path)
	return string.lower((string.gsub(path or "", "/+$", "")))
end

local function tabs_of(tabs)
	local out = {}
	for _, tab in tabs or {} do
		if type(tab) ~= "table" then continue end
		local copy = {title=tab.title, kind=tab.kind, cwd=tab.cwd, session=tab.session, pane=tab.pane, layout=tab.layout, panes=tab.panes}
		if type(copy.session) == "string" and copy.session ~= "" then
			table.insert(out, copy)
		elseif type(tab.title) == "string" and tab.title ~= "" and #out < MAX_TABS then
			table.insert(out, copy)
		end
		if #out >= MAX_TABS then break end
	end
	return out
end

local function project_key(project)
	if type(project.path) == "string" and project.path ~= "" then return "p:" .. norm(project.path) end
	return "n:" .. tostring(project.name)
end

-- A pane's session mapping can be empty for a poll after a reload or reset; a tab that matches a saved
-- one by folder and title keeps the saved omp session id instead of losing it.
local function keep_sessions(live_tabs, prior_tabs)
 local by_key = {}
 for _, tab in prior_tabs or {} do
  if type(tab.session) == "string" then by_key[norm(tab.cwd) .. "\0" .. tostring(tab.title)] = tab.session end
 end
 local prior_by_key = {}
 for _, tab in prior_tabs or {} do
  prior_by_key[norm(tab.cwd) .. "\0" .. tostring(tab.title)] = tab
 end
 for _, tab in live_tabs do
  local prior = prior_by_key[norm(tab.cwd) .. "\0" .. tostring(tab.title)]
  if prior then
   if not tab.session and type(prior.session) == "string" then tab.session = prior.session end
   if not tab.layout and prior.layout then tab.layout, tab.panes, tab.pane = prior.layout, prior.panes, prior.pane end
  end
 end
end

-- Merge the live tree over the saved one. Live entries win when they still have tabs; a project that
-- vanished keeps its last known tabs, which is the point of keeping this around. `at` is wall time.
function M.merge(saved, live, at)
	local saved_projects = if type(saved) == "table" and type(saved.projects) == "table" then saved.projects else {}
	local by_key = {}
	for _, project in saved_projects do
		if type(project) == "table" then by_key[project_key(project)] = project end
	end
	local live_projects = if type(live)=="table" and type(live.projects)=="table" then live.projects else live or {}
	local out = {}
	for _, project in live_projects do
		if type(project) ~= "table" or type(project.name) ~= "string" then continue end
		local key = project_key(project)
		local prior = by_key[key]
		local live_tabs = tabs_of(project.tabs)
		if prior then keep_sessions(live_tabs, tabs_of(prior.tabs)) end
		table.insert(out, {name=project.name, path=project.path,
			tabs=if #live_tabs > 0 then live_tabs else (if prior then tabs_of(prior.tabs) else {})})
		by_key[key] = nil
	end
	-- Projects older than the live ones, newest first, each kept once.
	for _, project in saved_projects do
		if type(project) ~= "table" then continue end
		local key = project_key(project)
		if by_key[key] then
			table.insert(out, {name=project.name, path=project.path, tabs=tabs_of(project.tabs)})
			by_key[key] = nil
		end
		if #out >= MAX_PROJECTS then break end
	end
	return {at=at, projects=out}
end

-- True when a saved tab has a layout with at least one agent pane that can be resumed.
function M.has_agents(tab)
	if type(tab) ~= "table" or type(tab.layout) ~= "table" or type(tab.panes) ~= "table" then return false end
	for _, pane in tab.panes do
		if type(pane) == "table" and type(pane.session) == "string" and pane.session ~= "" then return true end
	end
	return false
end

-- What is missing now: a saved project whose folder still exists and whose folder or name is not live.
-- Default is Tern's own fallback session, never restored. `exists(path)` checks the folder.
function M.plan(saved, live, exists)
	local live_projects = if type(live)=="table" and type(live.projects)=="table" then live.projects else live or {}
	local live_paths, live_names = {}, {}
	for _, project in live_projects do
		if type(project) ~= "table" then continue end
		local path = norm(project.path)
		if path ~= "" then live_paths[path] = true end
		if type(project.name) == "string" then live_names[string.lower(project.name)] = true end
	end
	local out, total_tabs = {}, 0
	for _, project in (if type(saved) == "table" and type(saved.projects) == "table" then saved.projects else {}) do
		if type(project) ~= "table" or type(project.name) ~= "string" then continue end
		local path = project.path
		if type(path) ~= "string" or path == "" or not exists(path) then continue end
		if string.lower(project.name) == "default" then continue end
		if live_paths[norm(path)] or live_names[string.lower(project.name)] then continue end
		local tabs = {}
		for _, tab in tabs_of(project.tabs) do
			-- A restorable tab carries a layout whose leaves include agent sessions; a plain top-level
			-- session is the older shape and still counts.
			if M.has_agents(tab) or type(tab.session) == "string" then
				table.insert(tabs, {title=tab.title, cwd=tab.cwd or path, session=tab.session,
					layout=tab.layout, panes=tab.panes, pane=tab.pane})
				if #tabs >= MAX_RESTORE_TABS then break end
			end
		end
		table.insert(out, {name=project.name, path=path, tabs=tabs})
		total_tabs += #tabs
		if #out >= MAX_PROJECTS then break end
	end
	return {projects=out, projects_count=#out, tabs_count=total_tabs}
end

-- `plan` with a small cache: the banner asks every render, but folders are only stat'ed every 30 s.
local plan_cache, plan_sig, plan_at = nil, nil, -math.huge
function M.plan_cached(saved, live, exists, now)
	local sig = tostring(if type(saved)=="table" then saved.at else nil) .. "\3" .. M.signature(live)
	if plan_sig ~= sig or now - plan_at >= 30000 then
		plan_sig, plan_at, plan_cache = sig, now, M.plan(saved, live, exists)
	end
	return plan_cache or {projects={},projects_count=0,tabs_count=0}
end

-- After a restore the cached plan is stale; recompute on the next render.
function M.invalidate_plan() plan_sig = nil end

-- True when the live tree differs enough from the last save to be worth writing: always after a
-- missing write or 15 s of quiet, else only when the shape (projects or their tabs) changed.
local last_sig, last_at = nil, -math.huge
function M.signature(live)
	local parts = {}
	for _, project in live or {} do
		table.insert(parts, tostring(project.name) .. "\0" .. tostring(project.path))
		for _, tab in project.tabs or {} do
			table.insert(parts, tostring(tab.session) .. "\1" .. tostring(tab.title))
		end
	end
	return table.concat(parts, "\2")
end
function M.should_save(live, now)
	local sig = M.signature(live)
	if sig ~= last_sig or now - last_at >= 15000 then
		last_sig, last_at = sig, now
		return true
	end
	return false
end

return M
