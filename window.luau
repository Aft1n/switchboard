local rendered_host
local model = require("./model")
local keyboard = require("./keyboard")
local close_target = require("./close_target")
local agent_state = require("./agent_state")
local placement = require("./placement")
local view = require("./view")
local progress = require("./progress")
local usage = require("./usage")
local subagents = require("./subagents")
local section_sizes = require("./section_sizes")
local terminal_agents = require("./terminal_agents")
local quotas = {}
local quota_state = "Loading limits…"
local quota_at = -math.huge
local quota_busy = false
local quota_started_at
local quota_generation = 0
local quota_epoch, quota_epoch_at
local chrome_running, chrome_waiting, chrome_done, chrome_quota, chrome_quota_tone, chrome_key
local PROVIDER_LABELS = {anthropic="Claude", ["openai-codex"]="Codex", ["google-antigravity"]="Gemini", commandcode="Command"}
local enabled = tern.kv.get("enabled") ~= false
local retry_at = 0
local PLUGIN_ID = tern.plugin.id
local owned = {}
local pending = {}
local is_canvas = {}
local creating = {}
-- Re-send the tree for a moment after a reload or a newly created sidebar: the
-- block host may not be listening yet, and a deduped event would be lost forever.
local force_until = tern.now() + 5000
local order_timer
local active_sidebar
local width_seen = {}
local applied_share = {}
local last = {}
local function forget_pane(pane)
	last[pane]=nil; width_seen[pane]=nil; applied_share[pane]=nil
end
local sidebar_snapshot
local sidebar_route
local changing = false
local ready = false
local clock
local live_clock
local activity_clock
local close_check
local activity = {}
local subagent_rows = tern.kv.get("subagent_rows") or {}
local status_reads={}
local completed_signals={}
local recency = tern.kv.get("agent_recency") or {next=0,panes={}}
-- Order moves on first sight and on real state transitions only; a snapshot or
-- transcript change never reshuffles the sidebar. Waiting-input sort keeps that
-- row on top regardless of the bump.
local selected_content
local visible_agents={}
local known_agent_tabs={}
local closing_empty_tabs={}
local closed_tabs_to_check={}
local jump_clock
local jump_after_close
local selected_workspace
local project_paths=tern.kv.get("project_paths") or {}
local agent_history_mod=require("./agent_history")
local agent_history=tern.kv.get("agent_history") or {}
local agent_sessions=require("./agent_sessions")
local executables=require("./executable")
local tern_bin=executables.tern_bin()
local ovnfs_cached
local function ovnfs_bin()
	if ovnfs_cached then return ovnfs_cached end
	local override=tern.getenv("OVNFS_BIN")
	if override and override ~= "" then ovnfs_cached=override; return override end
	local home=tern.getenv("HOME") or ""
	local candidates={"/opt/homebrew/bin/ovnfs","/usr/local/bin/ovnfs"}
	if home ~= "" then table.insert(candidates,1,home .. "/.local/bin/ovnfs") end
	for _,path in candidates do if tern.fs.exists(path) then ovnfs_cached=path; return path end end
	ovnfs_cached="ovnfs"
	return ovnfs_cached
end
local pane_sessions={}
local session_at,session_busy=-math.huge,false
local project_colors=require("./project_colors")
local project_colors_store=tern.kv.get("project_colors") or {next=1,colors={}}
-- 36 color rules for the project slots; switchboard.css only carries the 1..6 fallback.
tern.css("project-colors", project_colors.css())
local refresh
local isolation_from_path
local workspace_recency=require("./workspace_recency")
local workspace_order_mod=require("./workspace_order")
local workspace_stamps=tern.kv.get("workspace_recency") or {}
local workspace_order=tern.kv.get("workspace_order") or {}
local workspace_lift, workspace_view
local workspace_tab_counts={}
local stamped_session
local closing_native_tabs={}
local navigation_intent
local focused_by_tab = {}
local sidebar_share = tonumber(tern.kv.get("native_sidebar_share")) or 0.20
local workspace_expanded = tern.kv.get("workspace_expanded") or {}
local subagents_expanded = tern.kv.get("subagents_expanded") or {}
local shortcuts = tern.kv.get("shortcuts") or {}
local sidebar_settings = tern.kv.get("sidebar_settings") or {}

-- Harnesses running in terminal panes (see terminal_agents.luau), keyed by pane id.
local terminal_panes = {}
local terminal_scan = {at = -math.huge, busy = false}
local terminal_records = {}
local terminal_reads = {}
local remote_keys = {}
local terminal_notices = {}

local function agent_infos(cx)
	local infos=cx.agents:list()
	local now=tern.now()
	for _,info in infos do
		local raw=info.state
		-- A moved or just-resumed agent pane can still carry the previous
		-- session's "working" state. The pane's own busy flag is current.
		local pane=cx.session:pane(info.pane)
		if raw=="working" and pane and pane.busy==false then raw="idle" end
		local prior=activity[info.pane]
		if raw=="working" and prior and prior.empty_transcript
			and prior.snapshot and #(prior.snapshot.steps or {})==0
			and prior.snapshot.response==nil and prior.snapshot.todo==nil then raw="idle" end
		if raw=="idle" or raw=="exited" or raw=="waiting_input" then completed_signals[info.pane]=nil end
		local reported=completed_signals[info.pane] or raw
		if (raw=="working" or completed_signals[info.pane]) and info.pane==cx.session:focused() then
			local cached=status_reads[info.pane]
			if not cached or cached.raw~=raw or now-cached.at>=15000 then
				local ok,tree=pcall(function()return cx.session:view(info.pane,{nodes=512})end)
				local state,source=agent_state.reconcile(reported,if ok then tree else nil,nil)
				cached={raw=raw,state=state,source=source,at=now}
				status_reads[info.pane]=cached
			end
			if cached.source=="view" and cached.state=="working" then completed_signals[info.pane]=nil end
			info.state=cached.state
		else info.state=reported end
	end
	return infos
end

local function sample(cx, infos, read)
	local now = tern.now()
	local wall = os.time()*1000
	local seen = {}
	local by_pane = {}
	local focused = cx.session:focused()
	local changed=false
	for _, info in infos do by_pane[info.pane] = info end
	-- Another window may have ordered panes since this one last read.
	recency=tern.kv.get("agent_recency") or recency
	for _, info in infos do
		seen[info.pane] = true
		local record = activity[info.pane]
		local fresh = not record
		if fresh then
			record = {state=info.state, read_at=-math.huge, dirty=true, updated_at=now, snapshot={steps={}},subagents=subagents.clean(subagent_rows[string.format("%.0f",info.pane)] or {},wall)}
			activity[info.pane] = record
			local key=string.format("%.0f",info.pane)
			record.recent_order=recency.panes[key]
			if not record.recent_order then
				recency.next+=1
				recency.panes[key]=recency.next
				record.recent_order=recency.next
				changed=true
			end
		end
		if record.state ~= info.state then
			-- A real transition (working, waiting, finished) moves the row up; first
			-- sight already ordered it and transcript polls never bump.
			if not fresh then
				recency.next+=1
				local key=string.format("%.0f",info.pane)
				recency.panes[key]=recency.next
				record.recent_order=recency.next
				changed=true
			end
			record.dirty = true
			record.updated_at = now
			if record.state == "working" and info.state == "idle" then record.unseen = focused ~= info.pane; record.finished_at=now end
			if info.state == "working" then record.unseen=false; record.finished_at=nil; record.progress_completed_at=nil end
			if info.synthetic and info.state == "waiting_input" then table.insert(terminal_notices, {pane=info.pane, reason="Needs your input"}) end
			if info.synthetic and record.state == "working" and info.state == "idle" then table.insert(terminal_notices, {pane=info.pane, reason="Finished"}) end
		end
		if focused == info.pane then
			record.unseen = false
		end
		record.last_seen = now
		record.state = info.state
	if info.synthetic then record.read_at, record.dirty, record.synthetic = now, false, true end
	end
	for pane in activity do
		if not seen[pane] and now-(activity[pane].last_seen or now)>30000 then activity[pane]=nil; recency.panes[string.format("%.0f",pane)]=nil; changed=true end
	end
	if changed then tern.kv.set("agent_recency",recency) end
	if not read then return end
	local pick=progress.next_read(activity,now,focused)
	if pick then
		local record = activity[pick]
		local ok, messages = pcall(function()
			return cx.agents:transcript(pick, {last=60})
		end)
		if ok then
			local children=subagents.clean(subagents.scan(messages,record.subagents,now,wall),wall)
			if tern.json.encode(children)~=tern.json.encode(record.subagents) then
			 subagent_rows[string.format("%.0f",pick)]=children
			 tern.kv.set("subagent_rows",subagent_rows)
			end
			record.subagents=children
			record.empty_transcript=type(messages)~="table" or #messages==0
			local native_view
			if pick==focused and record.read_at ~= -math.huge
				and (record.dirty or not record.snapshot.todo or record.snapshot.todo.done<record.snapshot.todo.total) then
				local view_ok,tree=pcall(function() return cx.session:view(pick,{nodes=256}) end)
				if view_ok then native_view=tree end
			end
			local snapshot=progress.sample(messages,record.snapshot,record.state,native_view)
			if #record.subagents > 0 then
				-- Once the parent is idle, keep the finished batch's todo and steps as
				-- history: a later prompt clears the live snapshot, not the batch card.
				if snapshot.todo then record.history_todo=snapshot.todo end
				if #snapshot.steps > 0 then record.history_steps=snapshot.steps end
				if record.state=="idle" then
					if not snapshot.todo and record.history_todo then snapshot.todo=record.history_todo end
					if #snapshot.steps==0 and record.history_steps then snapshot.steps=record.history_steps end
				end
			end
			if record.read_at ~= -math.huge and tern.json.encode(snapshot) ~= tern.json.encode(record.snapshot) then
				record.updated_at=now
			end
			record.snapshot = snapshot
			if record.empty_transcript and #(snapshot.steps or {})==0
				and snapshot.response==nil and snapshot.todo==nil then
				-- OMP can report a just-created, prompt-less session as working.
				-- An empty transcript is the reliable signal that it is idle.
				local info=by_pane[pick]
				if info and info.state=="working" then info.state="idle" end
				record.state="idle"
				record.unseen=false
				record.finished_at=nil
			end
			local todo=snapshot.todo
			if todo and todo.done==todo.total and record.state=="idle" then record.progress_completed_at=record.progress_completed_at or now
			else record.progress_completed_at=nil end
		end
		record.unavailable = not ok
		record.read_at, record.dirty = now, false
	end
end

-- Owning host of a pane ("panes") or session ("sessions"); nil when unknown.
local function host_of(cx,field,id)
	for _, host in cx.hosts:list() do
		for _, item in host[field] or {} do if item == id then return host end end
	end
	return nil
end

-- Makes `host` current before an action that would otherwise run on the wrong host.
-- Returns false (after a toast) when the host is not connected.
local function use_host(cx,host)
	if not host then return true end
	if host.state ~= "connected" then cx:toast("info","Host unavailable",host.name .. " · " .. host.state); return false end
	if host.id ~= cx.hosts:current().id then cx.hosts:switch(host.id) end
	return true
end

-- Remote tabs run `omp` through their host's shell; local tabs need the resolved binary.
local function omp_cmd(host)
	if host and host.kind == "remote" then return "omp" end
	return executables.omp_bin()
end

-- Omp agents plus harnesses found in terminal panes. Terminal rows take their state from
-- screen reads, so they never reach the omp transcript path.
local function all_infos(cx)
	local infos = agent_infos(cx)
	local omp = {}
	for _, info in infos do omp[info.pane] = true end
	local next_remote, live = {}, {}
	for _, pane in cx.session:panes() do
		if pane.kind == "terminal" and not omp[pane.pane] and not owned[pane.pane] then
			local host = host_of(cx, "panes", pane.pane)
			local key
			if host and host.kind == "remote" then
				key = terminal_agents.classify_title(pane.title, pane.running and pane.running.line)
				if not key and not pane.at_prompt then key = remote_keys[pane.pane] end
				next_remote[pane.pane] = key
			else
				key = terminal_panes[pane.pane]
			end
			if key then
				live[pane.pane] = true
				table.insert(infos, {pane=pane.pane, state=(terminal_records[pane.pane] or {}).state or "idle", cwd=pane.cwd,
					title=terminal_agents.clean_title(pane.title, key, pane.cwd), model=terminal_agents.label(key), command=key, synthetic=true})
			end
		end
	end
	remote_keys = next_remote
	for pane in terminal_records do
		if not live[pane] then terminal_records[pane] = nil; terminal_reads[pane] = nil end
	end
	return infos
end

-- At most two screen reads per activity tick: the focused harness, then the least recently read.
local function read_terminal_screens(cx, infos)
	local now = tern.now()
	local focused = cx.session:focused()
	local due = {}
	for _, info in infos do
		if info.synthetic then table.insert(due, info) end
	end
	local function last_read(info)
		if info.pane == focused then return -math.huge end
		return terminal_reads[info.pane] or -math.huge
	end
	table.sort(due, function(a, b) return last_read(a) < last_read(b) end)
	for i = 1, math.min(2, #due) do
		local info = due[i]
		terminal_reads[info.pane] = now
		local ok, text = pcall(function() return cx.session:read(info.pane, {as="text", lines=25, scrollback=false}) end)
		if ok and type(text) == "string" then
			local record = terminal_agents.state(terminal_records[info.pane], text, now)
			terminal_records[info.pane] = record
			info.state = record.state
		end
	end
end

-- One process scan per 4 s finds harnesses in local panes (see terminal_agents.SCAN).
local function scan_terminals()
	local now = tern.now()
	if terminal_scan.busy or now - terminal_scan.at < 4000 then return end
	terminal_scan.at = now
	terminal_scan.busy = true
	local ok = pcall(tern.process.run, {"/bin/sh", "-c", terminal_agents.SCAN}, {timeout_ms = 5000}, function(result)
		terminal_scan.busy = false
		if result and result.status == 0 then terminal_panes = terminal_agents.parse_scan(result.stdout) end
	end)
	if not ok then terminal_scan.busy = false end
end

-- Local-only checkout/worktree classification for agent cards. One ovnfs and
-- one omp scan per 30 s; git checkout detection is cached per cwd.
local ISOLATION_TTL = 60000
local isolation_scan = {at = -math.huge, checkouts = {}, worktrees = {}, busy = false}
local isolation_git = {}

local function path_under(path, root)
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

local function path_name(path)
	return string.match(path, "([^/]+)/*$") or path
end

local function decode_json(text)
	local ok, value = pcall(tern.json.decode, text)
	return if ok then value else nil
end

local function scan_isolation(cx)
	if isolation_scan.busy or tern.now() - isolation_scan.at < ISOLATION_TTL then return end
	isolation_scan.busy = true
	local pending = 2
	local last_cx = cx
	local function finish(nextCx)
		if nextCx then last_cx = nextCx end
		pending -= 1
		if pending == 0 then
			isolation_scan.at = tern.now()
			isolation_scan.busy = false
			if last_cx then refresh(last_cx) end
		end
	end
	local checkouts = pcall(tern.process.run, {ovnfs_bin(), "ls", "--json"}, {timeout_ms = 5000}, function(result, nextCx)
		isolation_scan.checkouts = {}
		local data = decode_json(result.stdout)
		if result.status == 0 and type(data) == "table" and type(data.checkouts) == "table" then
			for _, co in data.checkouts do
				if type(co) == "table" and type(co.path) == "string" then
					isolation_scan.checkouts[#isolation_scan.checkouts + 1] = {
						path = co.path, name = co.name or path_name(co.path),
						source = tostring(co.source or ""), dirty = co.dirty == true,
					}
				end
			end
		end
		finish(nextCx)
	end)
	if not checkouts then finish(cx) end
	local managed = pcall(tern.process.run, {executables.omp_bin(), "worktree", "list", "--json"}, {timeout_ms = 5000}, function(result, nextCx)
		isolation_scan.worktrees = {}
		local data = decode_json(result.stdout)
		local list = if type(data) == "table" then (if type(data.worktrees) == "table" then data.worktrees else data) else nil
		if result.status == 0 and type(list) == "table" then
			for _, wt in list do
				if type(wt) == "table" and type(wt.path) == "string" then
					isolation_scan.worktrees[#isolation_scan.worktrees + 1] = {
						path = wt.path, name = wt.label or path_name(wt.path),
						detail = wt.branch or wt.state or "worktree",
					}
				end
			end
		end
		finish(nextCx)
	end)
	if not managed then finish(cx) end
end

local function git_isolation(cx, cwd)
	local now = tern.now()
	local entry = isolation_git[cwd]
	if entry and now - entry.at < ISOLATION_TTL then return entry end
	if entry and entry.pending then return entry end
	entry = {at = now, pending = true}
	isolation_git[cwd] = entry
	local ok = pcall(tern.process.run, {
		"/usr/bin/git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir", "--abbrev-ref", "HEAD",
	}, {timeout_ms = 5000}, function(result, nextCx)
		entry.pending = nil
		entry.at = tern.now()
		if result.status == 0 then
			local git_dir, common, branch = string.match(result.stdout, "^([^\n]*)\n([^\n]*)\n([^\n]*)")
			if git_dir and common and git_dir ~= common then
				entry.worktree = true
				entry.branch = if branch and branch ~= "HEAD" then branch else nil
			end
		end
		if nextCx then refresh(nextCx) end
	end)
	if not ok then entry.pending = nil end
	return entry
end

isolation_from_path = function(path)
	if type(path) ~= "string" or path == "" then return nil end
	local best_checkout = nil
	for _, item in isolation_scan.checkouts do
		if path_under(path, item.path) and (not best_checkout or #item.path > #best_checkout.path) then best_checkout = item end
	end
	if best_checkout then
		return {
			kind = "co", name = best_checkout.name,
			detail = (if best_checkout.dirty then "dirty" else "clean") .. " · " .. best_checkout.source,
			dirty = best_checkout.dirty,
		}
	end
	local best_tree = nil
	for _, item in isolation_scan.worktrees do
		if path_under(path, item.path) and (not best_tree or #item.path > #best_tree.path) then best_tree = item end
	end
	if best_tree then return {kind = "wt", name = best_tree.name, detail = best_tree.detail} end
	return nil
end

local function isolation_for(cx, cwd)
	if type(cwd) ~= "string" or cwd == "" then return nil end
	scan_isolation(cx)
	local known = isolation_from_path(cwd)
	if known then return known end
	local git = git_isolation(cx, cwd)
	if git and git.worktree then
		return {kind = "wt", name = path_name(cwd), detail = git.branch or "worktree"}
	end
	return nil
end

local session_isolation = {}
local session_scan_busy = false
local function isolation_from_session(cx, file)
	if type(file) ~= "string" or file == "" then return nil end
	local now = tern.now()
	local entry = session_isolation[file]
	if entry and now - entry.at < ISOLATION_TTL then return entry.iso end
	if entry and entry.pending then return entry.iso end
	scan_isolation(cx)
	if not next(isolation_scan.checkouts) and not next(isolation_scan.worktrees) then
		return entry and entry.iso
	end
	if session_scan_busy then return entry and entry.iso end
	session_scan_busy = true
	entry = {at = now, pending = true, iso = entry and entry.iso}
	session_isolation[file] = entry
	local ok = pcall(tern.process.run, {"/usr/bin/tail", "-n", "120", file}, {timeout_ms = 5000}, function(result, nextCx)
		entry.pending = nil
		entry.at = tern.now()
		session_scan_busy = false
		if result.status == 0 then
			local lines = {}
			for line in string.gmatch(result.stdout, "[^\n]+") do lines[#lines + 1] = line end
			-- The newest explicit path wins: a later `cd` or file read outside
			-- the checkout removes the badge instead of preserving old history.
			for i = #lines, 1, -1 do
				local decoded, value = pcall(tern.json.decode, lines[i])
				if decoded and type(value) == "table" and value.customType == "tool_execution_start" then
					local data = value.data
					local args = if type(data) == "table" then data.args else nil
					local candidate = nil
					if type(args) == "table" and type(args.path) == "string" and args.path ~= "" then
						candidate = args.path
					end
					-- A command that starts with `cd <absolute dir>` moves the working dir;
					-- shortcut: only the leading cd is read, later `cd`s in one command are not.
					if not candidate and type(args) == "table" and type(args.command) == "string" then
						local target = string.match(args.command, "^%s*cd%s+['\"]?(/[^%s;&|'\"]*)")
						if target then candidate = target end
					end
					if not candidate and type(data) == "table" and type(data.cwd) == "string" and data.cwd ~= "" then candidate = data.cwd end
					if candidate then
						candidate = string.gsub(candidate, "^['\"]", "")
						candidate = string.gsub(candidate, "['\"]$", "")
						entry.iso = isolation_from_path(candidate)
						-- `cd /tmp && ovnfs explain <checkout>` still works on the checkout.
						if not entry.iso and type(args) == "table" and type(args.command) == "string" then
							for _, item in isolation_scan.checkouts do
								if string.find(args.command, item.path, 1, true) then entry.iso = isolation_from_path(item.path); break end
							end
						end
						break
					end
				end
			end
		end
		if nextCx then refresh(nextCx) end
	end)
	if not ok then
		entry.pending = nil
		session_scan_busy = false
	end
	return entry.iso
end

local booted=false
local block_ready

local function discover(cx)
 owned,pending={},{}
 if not booted then
  -- A block from the previous plugin VM may look alive but exits with "no block
  -- type"; the canvas may belong to the previous owner. Close both once so the
  -- current VM opens a fresh sidebar instead of adopting an empty pane.
  booted=true
  for _,pane in cx.session:panes() do
   if pane.block=="switchboard.sidebar" then pcall(cx.layout.close,pane.pane) end
  end
  for _,c in cx.canvas:list() do
   if c.owner==PLUGIN_ID then pcall(cx.layout.close,c.pane) end
  end
 end
 -- A window-authored canvas is our own sidebar (and the only sidebar available
 -- on hosts without the plugin): adopt one per tab and drop extras.
 for _,c in cx.canvas:list() do
  if c.owner==PLUGIN_ID and cx.session:pane(c.pane) then
   local pane=c.pane
   local tab=cx.session:tab_of(pane)
   if tab and not pending[tab] then
    known_agent_tabs[pane]=nil
    if not is_canvas[pane] then
      forget_pane(pane)
    end
    owned[pane]=true
    is_canvas[pane]=true
    pending[tab]=pane
   else
    is_canvas[pane]=nil
    cx.layout:close(pane)
   end
  end
 end
 for _,pane in cx.session:panes() do
  if pane.block=="switchboard.sidebar" then
   local host=host_of(cx,"panes",pane.pane)
   local missing_block = pane.error and string.find(pane.error, "no block type", 1, true)
   if pane.exited or missing_block or (host and host.kind=="remote") or ((not host or host.current) and not block_ready(cx,"switchboard.sidebar")) then
    -- A block host from before a plugin rename exits with "no block type"; a
    -- remote host without the plugin must use the local canvas instead.
     forget_pane(pane.pane)
     is_canvas[pane.pane]=nil
    cx.layout:close(pane.pane)
   else
    local tab=pane.tab or cx.session:tab_of(pane.pane)
    if tab and pending[tab] then
      forget_pane(pane.pane)
     cx.layout:close(pane.pane)
    else
     owned[pane.pane]=true
     is_canvas[pane.pane]=nil
     if tab then pending[tab]=pane.pane end
    end
   end
  end
 end
 for pane in is_canvas do if not owned[pane] then is_canvas[pane]=nil end end
 -- Keep a just-created sidebar until the host lists it; otherwise the next
 -- poll forgets it and opens a duplicate with an empty view.
 for tab,entry in creating do
  if tern.now()-entry.at < 5000 then
   if not pending[tab] then pending[tab]=entry.pane end
   owned[entry.pane]=true
   if entry.canvas then is_canvas[entry.pane]=true end
  end
 end
end

local warned_block_hosts={}

block_ready=function(cx,kind)
 for _,block in cx.session:block_types() do if block.kind==kind then return true end end
 return false
end

local function hint_missing_host(cx,kind,title)
 local host=cx.hosts:current()
 if warned_block_hosts[host.id .. ":" .. kind] then return end
 warned_block_hosts[host.id .. ":" .. kind]=true
 cx:toast("info",title, "Switchboard could not draw its local sidebar here. Switch back with Switchboard: local host.")
end

local function place(cx,target,prewarm)
 local tab=target and cx.session:tab_of(target)
 if not tab then return end
 -- Capture only changes made to the previously shown native divider. A
 -- background tab's old share must never overwrite the saved global width.
 if active_sidebar and cx.session:pane(active_sidebar) then
  local previous_tab=cx.session:tab_of(active_sidebar)
  local previous=previous_tab and cx.session:layout(previous_tab)
  local width=previous and placement.share(previous.root,active_sidebar)
  if width and width_seen[active_sidebar] and math.abs(width-width_seen[active_sidebar])>0.002 then
   sidebar_share=math.clamp(width,0.15,0.6)
   tern.kv.set("native_sidebar_share",sidebar_share)
   applied_share[active_sidebar]=sidebar_share
  end
 end
 local pane=pending[tab]
 local shape=cx.session:layout(tab)
 if not shape then return end
 -- A freshly opened canvas or block can take a poll to appear in panes/canvas
 -- lists. Without this guard every refresh opened another sidebar.
 local guard=creating[tab]
 if guard then
  if cx.session:pane(guard.pane) and owned[guard.pane] then creating[tab]=nil
  elseif tern.now()-guard.at<5000 then return
  else creating[tab]=nil end
 end
 if not pane then
  local has_block=block_ready(cx,"switchboard.sidebar")
  local host=host_of(cx,"panes",target)
  -- Remote hosts and hosts without the plugin get the local window-half UI.
  local use_canvas=(host and host.kind=="remote") or not has_block
  if use_canvas then
   local ok,cane=pcall(function()
    return cx.canvas:open({title="Switchboard",view=tern.ui.col({}),how="beside",target=placement.first(shape.root),dir="left",ratio=sidebar_share,focus=false})
   end)
   if ok and cane then
    force_until=tern.now()+3000
    pane=cane
    owned[pane],pending[tab]=true,pane
    is_canvas[pane]=true
    creating[tab]={pane=pane,at=tern.now(),canvas=true}
    shape=cx.session:layout(tab)
   end
  end
  if not pane then
   if not has_block then
    hint_missing_host(cx,"switchboard.sidebar","Switchboard is not installed on this host")
    return
   end
   pane=cx:new_block("switchboard.sidebar",{sidebar_snapshot or ""},nil,{target=placement.first(shape.root),dir="left",ratio=sidebar_share,focus=false})
   if not pane then error("Cannot open Switchboard sidebar block") end
   force_until=tern.now()+3000
   owned[pane],pending[tab]=true,pane
   is_canvas[pane]=nil
   creating[tab]={pane=pane,at=tern.now(),canvas=false}
   shape=cx.session:layout(tab)
  end
 end
 local info=cx.session:pane(pane)
 if info.floating then cx.layout:dock(pane,target,"left",{focus=false}); shape=cx.session:layout(tab) end
 if shape.root.split=="right" and shape.root[1].pane==pane then
  if not active_sidebar and tern.kv.get("native_sidebar_share") then
   sidebar_share=math.clamp(shape.root.ratio,0.15,0.6)
   applied_share[pane]=sidebar_share
  end
  -- A stable visited tab never retunes itself on a status/title poll. Only
  -- a newly visited tab or a changed user width needs native ratio correction.
  if not applied_share[pane] or math.abs(applied_share[pane]-sidebar_share)>0.002
   or (pane~=active_sidebar and math.abs(shape.root.ratio-sidebar_share)>0.001) then
   placement.size(cx,tab,pane,sidebar_share)
   applied_share[pane]=sidebar_share
  end
 else
  local clean=model.clean_layout(shape.root,{[pane]=true})
  if clean then placement.wrap(cx,tab,pane,clean,sidebar_share) end
  applied_share[pane]=sidebar_share
  if not prewarm then cx.layout:focus(target) end
 end
 active_sidebar=pane
 local current=cx.session:layout(tab)
 width_seen[pane]=placement.share(current.root,pane)
 tern.kv.set("native_sidebar_share",sidebar_share)
end

local function mark_quotas_stale()
	quota_state=if #quotas>0 then "Limits may be stale · click to retry" else "Limits unavailable"
	for _,row in quotas do row.stale=true end
end

local function read_usage(cx, force)
	local now=tern.now()
	if quota_busy then
		if now-(quota_started_at or now)<65000 then return end
		quota_generation+=1
		quota_busy=false
		quota_started_at=nil
		quota_at=now
		mark_quotas_stale()
		return
	end
	local wall=quota_epoch and (quota_epoch+now-quota_epoch_at)
	local reset_due=wall and usage.reset_due(quotas,wall)
	if not force and now-quota_at < (if reset_due then 30000 else 60000) then return end
	quota_busy,quota_at=true,now
	quota_started_at=now
	quota_generation+=1
	local generation=quota_generation
	local executable = if tern.runtime.os == "macos" then (tern.getenv("HOME") or "") .. "/Library/Application Support/Tern/omp/bin/omp" else "omp"
	local function current() return quota_busy and generation==quota_generation end
	local function fail()
		if not current() then return end
		quota_busy=false
		quota_started_at=nil
		mark_quotas_stale()
	end
	local function fetch()
		tern.process.run({executable,"usage","--json","--redact"},{timeout_ms=45000},function(result)
			if not current() then return end
			local parsed,value=pcall(tern.json.decode,result.stdout)
			if result.status==0 and parsed and type(value)=="table" and type(value.reports)=="table" then
				local generated_at=if type(value.generatedAt)=="number" then value.generatedAt else wall
				local scanned,rows=pcall(usage.scan,value,generated_at)
				if not scanned then fail(); return end
				quotas=rows
				if generated_at then quota_epoch,quota_epoch_at=generated_at,tern.now() end
				quota_state=if #quotas==0 then "No reported limits" else nil
				for _,row in quotas do if row.stale then quota_state="Refreshing old limits…"; break end end
				quota_busy=false
				quota_started_at=nil
			else fail() end
		end)
	end
	local ok=pcall(function()
		if reset_due then
			-- Only a reset may clear OMP's cached reports; a manual refresh must not
			-- erase a provider that is not currently reporting.
			tern.process.run({executable,"usage","invalidate"},{timeout_ms=15000},function(result)
				if not current() then return end
				if result.status==0 then
					local started=pcall(fetch)
					if not started then fail() end
				else fail() end
			end)
		else fetch() end
	end)
	if not ok then fail() end
end


-- Tern pane ids are ephemeral, so ask inspect for each live agent's omp session
-- only while a pane is unmapped, its cwd moved, its title changed (OMP /new
-- swaps the session in place), or the mapping is older than 30 s. A pane that
-- reports no session is remembered per title/cwd so a shell at a reused pane id
-- never triggers an inspect every refresh.
local session_misses={}
local moved_sessions={}
local new_tab_titles={}
local function refresh_sessions(cx, agents, titles)
	if session_busy then return end
	local now=tern.now()
	if now-session_at<5000 then return end
	local wanted={}
	for _,agent in agents do
	if agent.synthetic or (agent.host and agent.host.kind=="remote") then continue end
		local key=tostring(agent.pane)
		local mapping=pane_sessions[key]
		local title=titles and titles[agent.pane]
		local stale=mapping and (not mapping.at or now-(mapping.at or 0)>=30000)
		local mismatch=not mapping
			or (mapping.cwd or "")~=(agent.cwd or "")
			or (title~=nil and mapping.title~=title)
		if not mismatch and not stale then session_misses[key]=nil; continue end
		-- A stale-but-matching mapping is re-read once per 30 s window.
		local bucket=if stale and not mismatch then math.floor(now/30000) else nil
		local sig=(agent.cwd or "").."\n"..(agent.name or "").."\n"..(title or "").."\n"
			..(mapping and mapping.session or "").."\n"..(bucket and tostring(bucket) or "")
		if session_misses[key]~=sig then table.insert(wanted,{key=key,sig=sig,cwd=agent.cwd or "",title=title}) end
	end
	if #wanted==0 then return end
	session_at=now
	session_busy=true
	local ok=pcall(tern.process.run,{tern_bin,"inspect","--json"},{timeout_ms=8000},function(result,nextCx)
		session_busy=false
		if not nextCx or not result or result.status~=0 then return end
		local old=pane_sessions
		local parsed=agent_sessions.parse(result.stdout)
		local at=tern.now()
		for _,mapping in parsed do mapping.at=at end
		for key in moved_sessions do if not nextCx.session:pane(tonumber(key) or key) then moved_sessions[key]=nil end end
		local moved=false
		-- Same pane with a different session in the same cwd is OMP /new.
		for _,key in agent_sessions.new_sessions(old,parsed) do
			local new=parsed[key]
			if moved_sessions[key]~=new.session then
				local pane=tonumber(key)
				if not pane or not nextCx.session:pane(pane) then continue end
				-- The pane id survived OMP /new, so its old transcript snapshot,
				-- state, subagents and ordering must not leak into the new session.
				activity[pane]=nil
				status_reads[pane]=nil
				completed_signals[pane]=nil
				subagent_rows[key]=nil
				if recency.panes[key] then
					recency.panes[key]=nil
					tern.kv.set("agent_recency",recency)
				end
				tern.kv.set("subagent_rows",subagent_rows)
				local old_mapping=old[key]
				local old_tab=nextCx.session:tab_of(pane)
				local old_sidebar=old_tab and pending[old_tab]
				local only=0
				if old_tab then
					for _,item in nextCx.session:panes() do
						if item.tab==old_tab and not owned[item.pane] then only+=1 end
					end
				end
				-- The old session keeps running unless history says it was not live.
				local old_session=nil
				local candidate=old_mapping and old_mapping.session
				if candidate and string.match(candidate,"^[%w%-]+$") then
					agent_history=tern.kv.get("agent_history") or agent_history
					for _,entry in agent_history do
						if entry.session==candidate and entry.live then old_session=candidate; break end
					end
				end
				if not old_session and old_tab and only==1 and old_sidebar then
					-- The old session is gone: a tab holding just this agent and its
					-- sidebar closes with the move instead of restoring emptied.
					closing_empty_tabs[old_tab]=true
					pcall(nextCx.layout.close,nextCx.layout,old_sidebar)
				end
				local focus=nextCx.session:focused()==pane
				local moved_ok,tab=pcall(function()
					return nextCx.layout:move_to_new_tab(pane,nil,{focus=focus})
				end)
				if not (moved_ok and tab) then continue end
				-- Tern carries the old tab's name into the new tab. Give the new
				-- session a neutral name until its own title arrives, so it never
				-- keeps the previous session's label.
				local pane_info=nextCx.session:pane(pane)
				local current_title=pane_info and pane_info.title
				local old_title=old_mapping and old_mapping.title
				if current_title and old_title and current_title~=old_title then
					pcall(function() nextCx.layout:name_tab(tab,nil) end)
				else
					pcall(function() nextCx.layout:name_tab(tab,"New chat") end)
					new_tab_titles[tab]={pane=pane,old=old_title or current_title}
				end
				moved_sessions[key]=new.session
				moved=true
				if old_session then
					-- Resume the old session beside the old tab's sidebar so both
					-- sessions stay active; never close the old pane's tab.
					local executable=omp_cmd(host_of(nextCx,"panes",pane))
					local command=agent_sessions.resume_command(executable,old_session)
					local resumed=false
					if command and old_sidebar and nextCx.session:pane(old_sidebar)
						and nextCx.session:tab_of(old_sidebar)==old_tab then
						local split_ok,split_pane=pcall(function()
							return nextCx.layout:split(old_sidebar,"right",{cwd=old_mapping.cwd or "",command=command},{focus=false})
						end)
						if split_ok and split_pane then
							pcall(placement.size,nextCx,old_tab,old_sidebar,sidebar_share)
							resumed=true
						end
					end
					if not resumed then
						pcall(function()
							nextCx.layout:new_tab({cwd=old_mapping.cwd or "",command=command},{focus=false})
						end)
					end
				end
			end
		end
		pane_sessions=parsed
		local any=false
		for _,item in wanted do
			local mapping=parsed[item.key]
			local previous=old[item.key]
			if mapping and (mapping.cwd or "")==item.cwd and (item.title==nil or mapping.title==nil or mapping.title==item.title) then
				session_misses[item.key]=nil
				-- A 30 s re-read of unchanged mappings must not force a render.
				if not previous or previous.session~=mapping.session or previous.cwd~=mapping.cwd or previous.title~=mapping.title then any=true end
			else session_misses[item.key]=item.sig end
		end
		if any or moved then refresh(nextCx) end
	end)
	if not ok then session_busy=false end
end

-- Infos from the last full refresh: a click that only changes presentation re-renders from them.
local last_infos

local function render(cx, infos, reveal_target, visible_only)
	local tabs = cx.session:tabs()
	-- A /new tab starts as "New chat"; hand it back to the pane label as soon as
	-- OMP gives the new session its own title.
	for tab,item in new_tab_titles do
		local info=cx.session:pane(item.pane)
		if not info then
			new_tab_titles[tab]=nil
		elseif info.title and (not item.old or info.title~=item.old) then
			pcall(function() cx.layout:name_tab(tab,nil) end)
			new_tab_titles[tab]=nil
		end
	end
	local layouts = {}
	for _, tab in tabs do layouts[tab.id] = cx.session:layout(tab.id) end
	local actual_focus = reveal_target or cx.session:focused()
	if actual_focus and not owned[actual_focus] then
		local tab = cx.session:tab_of(actual_focus)
		if tab then focused_by_tab[tab]=actual_focus end
	end
	local hosts_ok, hosts = pcall(function() return cx.hosts:list() end)
	if not hosts_ok then hosts={} end
	local panes=cx.session:panes()
	local data = model.build(cx.session:sessions(), tabs, panes, infos, owned, activity, layouts, focused_by_tab, hosts)
	for _, agent in data.agents do
	if agent.host and agent.host.kind == "local" and not agent.synthetic then
			agent.isolation = isolation_for(cx, agent.cwd)
			if not agent.isolation then
				local mapping = pane_sessions[tostring(agent.pane)]
				if mapping and mapping.file then agent.isolation = isolation_from_session(cx, mapping.file) end
			end
		end
	end
	visible_agents=data.agents
	-- Re-read shared kv so a second window cannot clobber newer history.
	agent_history=tern.kv.get("agent_history") or agent_history
	if agent_history_mod.update(agent_history,data.agents,tern.now(),pane_sessions) then tern.kv.set("agent_history",agent_history) end
	data.closed=agent_history_mod.closed(agent_history,data.agents)
	if #data.agents>0 then
		local titles={}
		for _,pane in panes do titles[pane.pane]=pane.title end
		refresh_sessions(cx,data.agents,titles)
	end
	local session_by_tab={}
	for _,session in cx.session:sessions() do for _,tab in session.tabs do session_by_tab[tab]=session.id end end
	-- Workspaces sort by wall-clock recency of launch/work (kv survives reloads and restarts).
	local wall_ms=os.time()*1000
	local stamps_changed=false
	local function touch_workspace(id,every)
		local key=workspace_recency.key(id)
		local at=workspace_stamps[key]
		if not at or wall_ms-at>=every then workspace_stamps[key]=wall_ms;stamps_changed=true end
	end
	local focus_tab=actual_focus and cx.session:tab_of(actual_focus)
	local focus_session=focus_tab and session_by_tab[focus_tab]
	if focus_session and focus_session~=stamped_session then stamped_session=focus_session;touch_workspace(focus_session,0) end
	local live_workspaces={}
	for _,project in data.projects do
		live_workspaces[workspace_recency.key(project.id)]=true
		-- Working agents keep a workspace fresh without reshuffling it every refresh.
		if (project.busy_tabs or 0)>0 then touch_workspace(project.id,300000) end
		local count=#project.tabs
		local before=workspace_tab_counts[project.id]
		if before and count>before then touch_workspace(project.id,0) end
		workspace_tab_counts[project.id]=count
	end
	for key in workspace_stamps do if not live_workspaces[key] then workspace_stamps[key]=nil;stamps_changed=true end end
	if stamps_changed then tern.kv.set("workspace_recency",workspace_stamps) end
	workspace_recency.sort(data.projects,workspace_stamps,wall_ms)
	workspace_order_mod.sort(data.projects,workspace_order)
	workspace_view=workspace_order_mod.ids(data.projects)
	if workspace_lift and not table.find(workspace_view,workspace_lift) then workspace_lift=nil end
	local paths_changed=false
	for _,pane in panes do
		local project=session_by_tab[pane.tab]
		if project and not owned[pane.pane] and type(pane.cwd)=="string" and string.sub(pane.cwd,1,1)=="/" then
			local key=string.format("%.0f",project)
			if not project_paths[key] then project_paths[key]=pane.cwd;paths_changed=true end
		end
	end
	if paths_changed then tern.kv.set("project_paths",project_paths) end
	for _,pane in panes do if not owned[pane.pane] and pane.tab then known_agent_tabs[pane.pane]=pane.tab end end
	for _,agent in data.agents do local tab=cx.session:tab_of(agent.pane);if tab then known_agent_tabs[agent.pane]=tab end end
	if selected_workspace then for _,project in data.projects do project.current=project.id==selected_workspace end end
	data.hosts=hosts
	for _, host in hosts do if host.current then data.host=host; break end end
	data.sidebar_host = cx.hosts:current().id
	data.section_sizes = section_sizes.read(tern.kv.get("section_sizes"))
	local active=reveal_target or cx.session:focused()
	data.sidebar_pane = active and pending[cx.session:tab_of(active)]
	data.now=tern.now()
	data.quotas, data.quota_state = quotas, quota_state
	-- The status line is global: counts from this refresh plus the lowest fresh quota.
	chrome_running, chrome_waiting = data.running or 0, data.waiting or 0
	chrome_done = 0
	for _, agent in data.agents do
		if agent.state == "done" then chrome_done += 1 end
	end
	chrome_quota, chrome_quota_tone = nil, nil
	local lowest = nil
	for _, q in quotas do
		if type(q) == "table" and not q.stale and type(q.remaining) == "number" then
			if not lowest or q.remaining < lowest.remaining then lowest = q end
		end
	end
	if lowest then
		local provider = lowest.provider or "Quota"
		chrome_quota = (PROVIDER_LABELS[provider] or provider) .. " " .. tostring(math.floor(lowest.remaining * 100 + 0.5)) .. "%"
		chrome_quota_tone = if lowest.remaining < 0.1 then "error" elseif lowest.remaining < 0.25 then "warn" else "muted"
	end
	local next_key = tostring(chrome_running) .. "|" .. tostring(chrome_waiting) .. "|" .. tostring(chrome_done) .. "|" .. (chrome_quota or "")
	if next_key ~= chrome_key then
		chrome_key = next_key
		tern.chrome.refresh()
	end
	data.quota_now = if quota_epoch and quota_epoch_at then quota_epoch+tern.now()-quota_epoch_at else nil
	data.shortcuts = shortcuts
	data.sidebar_settings = sidebar_settings
	data.workspace_expanded = workspace_expanded
	data.workspace_lift = workspace_lift
	data.subagents_expanded = subagents_expanded
	-- One stable color slot per project name, shared by workspace rows and agents.
	project_colors_store=tern.kv.get("project_colors") or project_colors_store
	local rebound=project_colors.rebalance(project_colors_store)
	local colors_added=rebound
	local function ensure_color(name)
		local colors=project_colors_store.colors
		local before=colors and colors[name]
		local known=type(before)=="number" and before%1==0 and before>=1 and before<=project_colors.TOTAL
		local color=project_colors.ensure(project_colors_store,name)
		if color and not known then colors_added=true end
	end
	for _,project in data.projects do ensure_color(project.name) end
	for _,agent in data.agents do ensure_color(agent.project) end
	for _,entry in data.closed do ensure_color(entry.project) end
	if colors_added then tern.kv.set("project_colors",project_colors_store) end
	data.project_colors = project_colors_store.colors
	local selected = cx.session:focused()
	if not selected_content and selected and not owned[selected] then selected_content=selected end
	local tree, sheet = view.render(tern.ui, data, reveal_target or selected_content or selected)
	-- Tern can clear a plugin's dynamic sheets during a style reload while the
	-- window VM keeps running. Reapply the current arcs with every render.
	tern.css("quota-arcs",sheet)
	local signature = tern.json.encode(tree)
	sidebar_snapshot=signature
	-- Every tab's sidebar shows the same global data. Updating only the focused
	-- tab's pane left a restored or reloaded visible sidebar on an old tree, so its
	-- row actions (lift/drop) never changed.
	-- A host switch remounts the other host's blocks; resend the tree instead of trusting `last`.
	local host_id=cx.hosts:current().id
	local force = tern.now() < force_until or host_id ~= rendered_host
	rendered_host=host_id
	for pane in owned do
		if (force or last[pane] ~= signature) and (not visible_only or pane == data.sidebar_pane) then
			if is_canvas[pane] then
				local ok=pcall(cx.canvas.set,cx.canvas,pane,{view=tree})
				if ok then last[pane] = signature end
			else
				-- A sidebar pane can outlive its program for a poll; one dead pane
				-- must not abort the updates for every other sidebar.
				local ok=pcall(function() cx.session:event(pane,{ev="action",act="switchboard.sidebar.update",value=signature}) end)
				if ok then last[pane]=signature end
			end
		end
	end
end

-- Tern drops plugin sheets on a style reload and on every plugin reload, and the native
-- rail (with its own tab list and 212px panel offset) shows until this is back. Send it at
-- load and with every refresh (idempotent), not only once the first poll has run.
local function apply_navigation()
	tern.css("navigation", [[
	:root { --vt-room:0px !important; --vt-w:0px !important; }
	:root #panel, :root #widgetbar { left:0 !important; }
	:root #sidebar, :root #tabbar { display:none !important; pointer-events:none !important; }
	.tn-pane:has(.switchboard) .tn-veil { display:none !important; }
	.tn-pane:has(.switchboard), .tn-pane:has(.switchboard) .tn-body,
	.tn-pane:has(.switchboard) .tv, .tn-pane:has(.switchboard) .tv-cover,
	.tn-pane:has(.switchboard) .sf-main, .tn-pane:has(.switchboard) .sf-unfocused {
		opacity:1 !important; filter:none !important;
	}
	.tn-pane:has(.switchboard) .tn-head { display:none !important; }
	.tn-pane:has(.switchboard) .tn-body { border-radius:var(--cp-corner) !important; }
	]] .. (if tern.runtime.os=="macos" then [[
	.tn-pane:has(.switchboard) .switchboard { padding-top:calc(6px + 20px / var(--tn-zoom,1)); }
	]] else ""))
end
if enabled then apply_navigation() end

-- Give one sidebar-less tab on the current host its sidebar per refresh, so switching to it
-- (natively or by changing host) shows a finished tab instead of a bare one that grows a
-- sidebar a frame later. Native blocks can only open on the current host, so other hosts'
-- tabs cannot be prepared from here.
local function prewarm_next(cx)
	local host=cx.hosts:current()
	local focused_tab=cx.session:focused() and cx.session:tab_of(cx.session:focused())
	for _,tab in cx.session:tabs() do
		if tab.id~=focused_tab and not pending[tab.id] and not creating[tab.id] then
			local owner=host_of(cx,"panes",tab.pane)
			local shape=owner and owner.id==host.id and cx.session:layout(tab.id)
			local content=shape and placement.first(model.clean_layout(shape.root,owned))
			if content then
				local keep=active_sidebar
				pcall(place,cx,content,true)
				active_sidebar=keep
				return
			end
		end
	end
end

refresh = function(cx, read)
	if tern.now() < retry_at then return end
	if not enabled or changing or not ready then return end
	if not cx.session:focused() then return end
	
	changing = true
	local ok, err = pcall(function()
		apply_navigation()
		discover(cx)
		local target = cx.session:focused()
		if target and owned[target] then
			local tab=cx.session:tab_of(target)
			local shape=tab and cx.session:layout(tab)
			if shape and not model.clean_layout(shape.root,owned) then
				changing=false
				closed_tabs_to_check[tab]=true
				jump_after_close(cx)
				return
			end
		end
		if target and not owned[target] then place(cx,target) end
		prewarm_next(cx)
		local infos = all_infos(cx)
		sample(cx, infos, read == true)
		last_infos = infos
		render(cx, infos)
		local current_pane=cx.session:focused()
		local current_tab=current_pane and cx.session:tab_of(current_pane)
		if not current_tab or not pending[current_tab] then return end
		if read then read_usage(cx) end
	end)
	changing = false
	if not ok then
		-- A closed remote tab can make one pass fail (a host or layout in flight).
		-- Retry instead of pausing until the user runs Show again.
		retry_at = tern.now() + 5000
		tern.css("navigation", "")
		cx:toast("error", "Switchboard refresh failed", tostring(err))
	end
end

local function restore(cx)
	local focused=cx.session:focused()
	local tab=focused and cx.session:tab_of(focused)
	local current=tab and pending[tab]
	local shape=tab and cx.session:layout(tab)
	local width=shape and placement.share(shape.root,current)
	if width then sidebar_share=math.clamp(width,0.15,0.6); tern.kv.set("native_sidebar_share",sidebar_share) end
	enabled = false
	tern.kv.set("enabled", false)
	tern.css("navigation", "")
	tern.css("quota-arcs", "")
	discover(cx)
	for pane in owned do cx.layout:close(pane) end
	owned, last, pending, is_canvas, creating, width_seen, applied_share = {}, {}, {}, {}, {}, {}, {}
	active_sidebar=nil
end

local function prewarm_agent_tab(cx,target)
	local tab=cx.session:tab_of(target)
	if not tab then return end
	discover(cx)
	if pending[tab] then return end
	place(cx,target,true)
	render(cx,agent_infos(cx),target)
end

-- Read a shallow transcript index first, then only the actual task subtrees.
-- A deep read from the start of a long transcript can exhaust its node budget
-- before reaching current task calls, leaving an old set of children frozen.
local function read_native_subagents(cx)
 local now=tern.now()
 local wall=os.time()*1000
 local pick,oldest
 for pane,record in activity do
  local due=(record.subagent_read_at or -math.huge)+(if record.state=="working" or #(record.subagents or {})>0 then 2000 else 10000)
 if not record.synthetic and due<=now and (not pick or due<oldest) then pick,oldest=pane,due end
 end
 if not pick then return end
 local record=activity[pick]
 record.subagent_read_at=now
 local ok,index=pcall(function()return cx.session:surface(pick,{root="main",depth=1,nodes=5000})end)
 if not ok then return end
 local roots=subagents.task_roots(index)
 if #roots==0 then return end
 record.subagent_cursor=((record.subagent_cursor or 0)%#roots)+1
 local root=roots[record.subagent_cursor]
 local read_ok,surface=pcall(function()return cx.session:surface(pick,{root=root,depth=3,nodes=1000})end)
 if not read_ok then return end
 local children=subagents.clean(subagents.from_surface(surface,record.subagents,now,wall),wall)
 if tern.json.encode(children)~=tern.json.encode(record.subagents) then
  record.subagents=children
  subagent_rows[string.format("%.0f",pick)]=children
  tern.kv.set("subagent_rows",subagent_rows)
 end
end

local function navigate(cx,requested)
	if not requested then return false end
	if selected_content==requested and cx.session:focused()==requested then
		selected_workspace=nil
		return true
	end
	if not cx.session:pane(requested) then
		cx:toast("info","Agent is no longer open")
		refresh(cx)
		return false
	end
	if not use_host(cx,host_of(cx,"panes",requested)) then return false end
	changing=true
	selected_workspace=nil
	selected_content = requested
	navigation_intent=if cx.session:focused()==requested then nil else requested
	local tab=cx.session:tab_of(requested)
	if tab then focused_by_tab[tab]=requested end
	if tab then pcall(prewarm_agent_tab,cx,requested) end
	if tab then
		for _,info in cx.session:tabs() do
			if info.id==tab and info.session~=cx.sessions:current().id then cx.sessions:switch(info.session);break end
		end
	end
	cx.layout:focus(requested)
	if cx.session:focused()==requested then navigation_intent=nil end
	changing=false
	refresh(cx)
	return true
end

jump_after_close=function(cx)
	changing=true
	local must_jump=false
	local panes=cx.session:panes()
	for tab in closed_tabs_to_check do
		local content=false
		for _,pane in panes do if pane.tab==tab and not owned[pane.pane] then content=true;break end end
		if not content then
			must_jump=true
			local sidebar=pending[tab]
			if sidebar and cx.session:pane(sidebar) then
				closing_empty_tabs[tab]=true
				cx.layout:close(sidebar)
			end
		end
	end
	closed_tabs_to_check={}
	changing=false
	if not must_jump then return end
	local target=close_target.select(visible_agents,cx.session:panes(),cx.session:tabs(),cx.session:sessions(),nil,owned,cx.hosts:list(),cx.hosts:current().id)
	if target then enabled=true;if navigate(cx,target) then return end end
	for _,session in cx.session:sessions() do
		if string.lower(session.name)=="default" then
			cx.sessions:switch(session.id)
			cx.layout:new_tab({cwd=tern.getenv("HOME") or ""})
			enabled=true;refresh(cx);return
		end
	end
	cx.sessions:create({name="Default",cwd=tern.getenv("HOME") or ""})
	enabled=true;refresh(cx)
end

tern.route.link(function(link,cx)
 if string.sub(link.url,1,22)=="switchboard://sidebar/" then
  if sidebar_route then return sidebar_route(link,cx) end
  return {handled=true}
 end
 return nil
end)

local function shortcut_guide(cx)
	local effective=cx.actions:keys()
	local function key_hint(action)
		local chords=keyboard.chords(effective,action)
		for i,chord in chords do
			if tern.runtime.os=="macos" then
				chord=string.gsub(string.gsub(string.gsub(string.gsub(chord,"alt%+","⌥"),"shift%+","⇧"),"ctrl%+","⌃"),"meta%+","⌘")
			end
			chords[i]=chord
		end
		return if #chords>0 then table.concat(chords," · ") else "Command palette"
	end
	local items={}
	for _,entry in {
		{"next-agent","Next agent"},{"previous-agent","Previous agent"},
		{"inbox","Tern needs you"},
	} do
		local id="plugin.switchboard." .. entry[1]
		table.insert(items,{label=entry[2],detail=key_hint(id),command=entry[1]})
	end
	for index,agent in visible_agents do
		if index>9 then break end
		table.insert(items,{label=agent.name,group="Jump to agent",detail=key_hint("plugin.switchboard.agent-" .. index),pane=agent.pane})
	end
	cx:pick({items=items,placeholder="Switchboard shortcuts"}):next(function(item,err,nextCx)
		if err or not item or not nextCx then return end
		if item.pane then navigate(nextCx,item.pane)
		elseif item.command=="next-agent" then navigate(nextCx,keyboard.next(visible_agents,nextCx.session:focused()))
		elseif item.command=="previous-agent" then navigate(nextCx,keyboard.previous(visible_agents,nextCx.session:focused()))
		elseif item.command=="inbox" then nextCx:command("inbox") end
	end)
end

local function sidebar_width_menu(cx)
	local items={}
	for _,percent in {16,18,20,22,24,28,32,40} do
		table.insert(items,{label=tostring(percent) .. "% of window",share=percent/100,current=math.abs(sidebar_share-percent/100)<0.01})
	end
	cx:pick({items=items,placeholder="Sidebar width · or drag Tern's divider"}):next(function(item,_,nextCx)
		if not item then return end
		sidebar_share=item.share
		tern.kv.set("native_sidebar_share",sidebar_share)
		local focus=nextCx.session:focused()
		local tab=focus and nextCx.session:tab_of(focus)
		local pane=tab and pending[tab]
		if tab and pane then placement.size(nextCx,tab,pane,sidebar_share); applied_share[pane]=sidebar_share; width_seen[pane]=placement.share(nextCx.session:layout(tab).root,pane) end
		refresh(nextCx)
	end)
end

local function sidebar_setting_on(name, default)
	local value=sidebar_settings[name]
	return if value==nil then default else value==true
end

local function settings_menu(cx)
	local items={
		{label="Show closed agents", detail="Remembered agents that closed, until the broom clears them", toggle="closed", default=true, current=sidebar_setting_on("closed",true)},
		{label="Show current step", detail="The latest tool step on each agent card", toggle="steps", default=true, current=sidebar_setting_on("steps",true)},
		{label="Show host badges", detail="Local or remote host marker on agent cards", toggle="hosts", default=true, current=sidebar_setting_on("hosts",true)},
		{label="Show provider quotas", detail="The provider rings in the footer", toggle="quotas", default=true, current=sidebar_setting_on("quotas",true)},
		{label="Keyboard shortcuts", detail="Open the shortcut helper", action="shortcuts"},
		{label="Sidebar width", detail=tostring(math.floor(sidebar_share*100+0.5)) .. "% of window", action="width"},
	}
	cx:pick({items=items,placeholder="Switchboard settings"}):next(function(item,err,nextCx)
		if err or not item or not nextCx then return end
		if item.toggle then
			sidebar_settings[item.toggle]=not sidebar_setting_on(item.toggle,item.default)
			tern.kv.set("sidebar_settings",sidebar_settings)
			refresh(nextCx)
			settings_menu(nextCx)
		elseif item.action=="shortcuts" then shortcut_guide(nextCx)
		elseif item.action=="width" then sidebar_width_menu(nextCx)
		end
	end)
end

local function new_project_tab(cx,project,path)
	if not use_host(cx,host_of(cx,"sessions",project)) then return end
	project_paths[string.format("%.0f",project)]=path
	tern.kv.set("project_paths",project_paths)
	selected_workspace=nil;navigation_intent=nil;selected_content=nil
	changing=true
	local ok,err=pcall(function()
		cx.sessions:switch(project)
		cx.layout:new_tab({cwd=path})
	end)
	changing=false
	if not ok then cx:toast("error","Could not open project tab",tostring(err)) end
	refresh(cx)
end
tern.override("new_tab",function(cx)
	if not selected_workspace then return false end
	local project=selected_workspace
	local path=project_paths[string.format("%.0f",project)]
	if path then new_project_tab(cx,project,path);return true end
	-- Older empty sessions do not expose a folder through the SDK. Remember a
	-- chosen root once instead of silently inheriting an unrelated pane's cwd.
	local owner=host_of(cx,"sessions",project) or cx.hosts:current()
	if tern.runtime.os=="macos" and owner.kind=="local" then
		tern.process.run({"/usr/bin/osascript","-e",'POSIX path of (choose folder with prompt "Choose this project’s folder")'}, {timeout_ms=600000},function(result,nextCx)
			if result.status==0 and nextCx and selected_workspace==project then
				new_project_tab(nextCx,project,(string.gsub(result.stdout,"[\r\n]+$","")))
			end
		end)
	else
		cx:prompt({placeholder="Project folder — absolute path"}):next(function(value,err,nextCx)
			if not err and nextCx and type(value)=="string" and string.sub(value,1,1)=="/" and selected_workspace==project then new_project_tab(nextCx,project,value) end
		end)
	end
	return true
end)
tern.override("close_tab",function(cx)
	local pane=cx.session:focused()
	local tab=pane and cx.session:tab_of(pane)
	if tab then closing_native_tabs[tab]=true end
	return false
end)

-- Closing a tab's last content pane leaves its sidebar alone at full width until the close event
-- is handled. Move to the next target first, then close the pane and its sidebar out of sight.
-- Busy panes fall through to Tern's own close so its confirmation still applies.
local function close_last_pane(cx)
	local pane=cx.session:focused()
	local tab=pane and not owned[pane] and cx.session:tab_of(pane)
	local sidebar=tab and pending[tab]
	if not sidebar then return false end
	local info=cx.session:pane(pane)
	if info and info.busy then return false end
	for _,item in cx.session:panes() do
		if item.tab==tab and item.pane~=pane and not owned[item.pane] then return false end
	end
	for _,agent in visible_agents do
		if agent.pane==pane and agent.state~="idle" and agent.state~="done" then return false end
	end
	local target=close_target.select(visible_agents,cx.session:panes(),cx.session:tabs(),cx.session:sessions(),tab,owned,cx.hosts:list(),cx.hosts:current().id)
	if not target or not navigate(cx,target) then return false end
	closing_empty_tabs[tab]=true
	cx.layout:close(pane)
	pcall(cx.layout.close,cx.layout,sidebar)
	return true
end
for _,id in {"close","close_pane"} do pcall(tern.override,id,close_last_pane) end

local function show_sidebar(cx)
	if close_check then close_check:cancel(); close_check=nil end
	ready = true
	force_until = tern.now() + 3000
	last={}
	for tab,pane in pending do if not cx.session:pane(pane) then pending[tab]=nil end end
	enabled = true
	tern.kv.set("enabled", true)
	refresh(cx)
end
tern.command({id="show", title="Show Switchboard sidebar", run=show_sidebar})
local function toggle_sidebar(cx)
	if enabled then restore(cx) else show_sidebar(cx) end
end
tern.command({id="toggle", title="Toggle Switchboard sidebar", run=toggle_sidebar})
tern.command({id="sb", title="SB: toggle Switchboard sidebar", run=toggle_sidebar})
tern.command({id="new-chat-tab", title="Switchboard: new chat in a new tab", run=function(cx)
	local focused=cx.session:focused()
	local path
	local pane=focused and cx.session:pane(focused)
	if pane then path=pane.cwd end
	for _,agent in cx.agents:list() do if agent.pane==focused then path=agent.cwd end end
	local host=host_of(cx,"panes",focused)
	if not use_host(cx,host) then return end
	local tab=cx.layout:new_tab({cwd=path or tern.getenv("HOME") or "",command=omp_cmd(host)},{focus=true})
	if not tab then cx:toast("error","Could not open a chat tab"); return end
	-- The tab reaches the layout on the next frame; ordering it immediately is a no-op.
	-- Keep the handle rooted or Lua collects the timer before it fires.
	order_timer=tern.timer(100,function(nextCx)
		order_timer=nil
		if nextCx then pcall(function() nextCx.layout:order_tab(tab,1) end) end
	end)
end})
tern.command({id="restore", title="Restore Tern sidebar", run=restore})
tern.command({id="usage", title="Switchboard: refresh provider quotas", run=function(cx) read_usage(cx, true) end})
tern.chrome.status(function(_pane)
	local segments = {}
	if chrome_running and chrome_running > 0 then
		table.insert(segments, {text = tostring(chrome_running) .. " running", tone = "ok", icon = "timer"})
	end
	if chrome_waiting and chrome_waiting > 0 then
		table.insert(segments, {text = tostring(chrome_waiting) .. " need", tone = "warn", icon = "inbox", command = "plugin.switchboard.inbox"})
	end
	if chrome_done and chrome_done > 0 then
		table.insert(segments, {text = tostring(chrome_done) .. " done", tone = "accent", icon = "check"})
	end
	if chrome_quota then
		table.insert(segments, {text = chrome_quota, tone = chrome_quota_tone, command = "plugin.switchboard.usage"})
	end
	if #segments == 0 then return nil end
	return segments
end)
tern.command({id="local-host", title="Switchboard: local host", run=function(cx)
	for _,host in cx.hosts:list() do
		if host.kind=="local" and host.state=="connected" then
			if not host.current then cx.hosts:switch(host.id); refresh(cx) end
			return
		end
	end
end})
tern.command({id="next-agent",title="Switchboard: next agent",run=function(cx)navigate(cx,keyboard.next(visible_agents,cx.session:focused()))end})
tern.command({id="previous-agent",title="Switchboard: previous agent",run=function(cx)navigate(cx,keyboard.previous(visible_agents,cx.session:focused()))end})
tern.command({id="shortcuts",title="Switchboard: keyboard shortcuts",run=shortcut_guide})
tern.command({id="inbox",title="Switchboard: Tern needs you",run=function(cx)cx:action("inbox")end})
for _,binding in {{"alt+j","next-agent"},{"alt+k","previous-agent"},{"alt+shift+n","new-chat-tab"},{"alt+/","shortcuts"},{"alt+shift+s","toggle"}} do
	tern.bind(binding[1],"plugin.switchboard." .. binding[2])
end
for index=1,9 do
	tern.command({id="agent-" .. index,title="Switchboard: agent " .. index,run=function(cx)navigate(cx,keyboard.at(visible_agents,index))end})
	tern.bind("alt+shift+" .. index,"plugin.switchboard.agent-" .. index)
end

local function sidebar_action(ev, cx)
	if ev.owner ~= PLUGIN_ID then return false end
	-- Click on a closed agent card: reopen its omp session in a new tab. The id is
	-- validated here and comes from the durable session, never from typed text.
	local resume=string.match(ev.act,"^resume%-session:([%w%-]+)$")
	if resume then
		local entry
		for _,item in agent_history do if item.session==resume then entry=item; break end end
		if not entry then cx:toast("info","Session is no longer in history"); return true end
		local host
		for _,item in cx.hosts:list() do if item.name==entry.host then host=item; break end end
		if not use_host(cx,host) then return true end
		-- A remote tab runs its command through that host's shell, so it resolves `omp` itself.
		local tab=cx.layout:new_tab({cwd=entry.cwd,command=string.format("%q --resume %s",omp_cmd(host),resume)},{focus=true})
		if not tab then cx:toast("error","Could not resume " .. (entry.name or resume)); return true end
		refresh(cx)
		return true
	end
	local parent_id=string.match(ev.act,"^subagents:(%d+)$")
	if parent_id then
	 subagents_expanded[parent_id]=not subagents_expanded[parent_id]
	 tern.kv.set("subagents_expanded",subagents_expanded)
	 -- Presentation-only change: re-render the visible sidebar from the last infos; other tabs'
	 -- sidebars catch up on the next poll instead of delaying this click.
	 if not (last_infos and pcall(render,cx,last_infos,nil,true)) then refresh(cx) end
	 return true
	end
	local parent,encoded=string.match(ev.act,"^subagent:(%d+):(.+)$")
	if parent then
	 local id=string.gsub(encoded,"%%(%x%x)",function(hex) return string.char(tonumber(hex,16)) end)
	 local parent_pane=tonumber(parent)
	 local child
	 for _,item in (activity[parent_pane] and activity[parent_pane].subagents) or {} do
	  if tostring(item.id)==id then child=item;break end
	 end
	 if not child then cx:toast("info","Subagent is no longer available");return true end
	 if navigate(cx,parent_pane) then
	  local surface=cx.session:surface(parent_pane,{root="dock",nodes=300})
	  local event=subagents.focus_event(surface,id)
	  if event then cx.session:event(parent_pane,event)
	  else cx:toast("info","Native subagent chat is not available","The parent’s OMP composer is not mounted yet. Try again once it is ready.") end
	 end
	 return true
	end
	local requested = tonumber(string.match(ev.act,"^pane:(%d+)$"))
	if requested then
	 if navigate(cx,requested) then
	  -- Selecting a parent card must leave any child previously focused inside
	  -- that same OMP pane. Child-card navigation deliberately bypasses this.
	  local surface=cx.session:surface(requested,{root="dock",nodes=300})
	  local event=subagents.parent_event(surface)
	  if event then cx.session:event(requested,event) end
	 end
	 return true
	end
	local focused=cx.session:focused()
	if focused and owned[focused] and selected_content and cx.session:tab_of(selected_content)==cx.session:tab_of(focused) then cx.layout:focus(selected_content) end
	local copy_pane=tonumber(string.match(ev.act,"^copy%-cwd:(%d+)$"))
	if copy_pane then
		local pane=cx.session:pane(copy_pane)
		local path=pane and pane.cwd
		for _,agent in cx.agents:list() do if agent.pane==copy_pane then path=agent.cwd; break end end
		if type(path)=="string" and path~="" then cx:copy(path); cx:toast("success","Working directory copied") end
		return true
	end
	if ev.act=="shortcuts" then shortcut_guide(cx);return true end
	local close_tab=tonumber(string.match(ev.act,"^close%-tab:(%d+)$"))
	if close_tab then
		local shape=cx.session:layout(close_tab)
		local target=shape and placement.first(model.clean_layout(shape.root,owned))
		if target and navigate(cx,target) and cx.session:tab_of(cx.session:focused())==close_tab then cx:command("close_tab") end
		return true
	end
	if ev.act == "keep-focus" then return true end
	if ev.act == "restore" then restore(cx); return true end
	local close_workspace=tonumber(string.match(ev.act,"^close%-workspace:(%d+)$"))
	if close_workspace then
		for _,session in cx.session:sessions() do
			if session.id==close_workspace then
				local count=#session.tabs
				local function close(later)
					if not use_host(later,host_of(later,"sessions",close_workspace)) then return end
					later.sessions:close(close_workspace)
					workspace_expanded[tostring(close_workspace)]=nil
					tern.kv.set("workspace_expanded",workspace_expanded)
					if selected_workspace==close_workspace then selected_workspace=nil end
					if workspace_lift==tostring(close_workspace) then workspace_lift=nil end
					refresh(later)
				end
				if count==0 then close(cx)
				else
					-- Closing ends every program in the workspace, so ask first.
					cx:pick({items={
						{label="Close " .. session.name,detail=tostring(count) .. (if count==1 then " tab" else " tabs") .. " · ends their programs",icon="x",key="close"},
						{label="Cancel",key="cancel"},
					},placeholder="Close workspace?",action="select"}):next(function(item,err,later)
						if err or not item or not later or item.key~="close" then return end
						close(later)
					end)
				end
				break
			end
		end
		return true
	end
	local function workspace_name(id)
		for _,session in cx.session:sessions() do if tostring(session.id)==id then return session.name end end
		return nil
	end
	local function move_workspace(target)
		force_until=tern.now()+2000
		local moved=workspace_order_mod.move(workspace_view or {},workspace_lift,target)
		if moved then
			workspace_order=moved
			tern.kv.set("workspace_order",workspace_order)
			cx:toast("success","Workspace moved",workspace_name(target))
		end
		workspace_lift=nil
		refresh(cx)
	end
	local lift=string.match(ev.act,"^lift%-workspace:(%d+)$")
	if lift then
		force_until=tern.now()+2000
		workspace_lift = if workspace_lift == lift then nil else lift
		if workspace_lift then cx:toast("info","Workspace picked up","Click a workspace to move it there; click it again to cancel.") end
		refresh(cx)
		return true
	end
	local drop_target=string.match(ev.act,"^drop%-workspace:(%d+)$")
	if drop_target then
		if workspace_lift then move_workspace(drop_target) else refresh(cx) end
		return true
	end
	local project=tonumber(string.match(ev.act,"^select%-workspace:(%d+)$"))
	if project then
		if workspace_lift then
			if workspace_lift==tostring(project) then workspace_lift=nil; refresh(cx) else move_workspace(tostring(project)) end
			return true
		end
		for _,session in cx.session:sessions() do
			if session.id==project then
				if not use_host(cx,host_of(cx,"sessions",project)) then return true end
				selected_workspace=project
				workspace_expanded[tostring(project)]=true
				refresh(cx)
				cx:toast("info",session.name,"Project selected · ⌘T to open a tab")
				break
			end
		end
		return true
	end
	local workspace = string.match(ev.act,"^fold%-workspace:(.+)$")
	if workspace then
		-- A row keeps its normal click action; while a workspace is picked up, that
		-- click drops it. The block tree need not swap every row's action in time.
		if workspace_lift then
			if workspace_lift==workspace then workspace_lift=nil; refresh(cx) else move_workspace(workspace) end
			return true
		end
		local expanded = workspace_expanded[workspace]
		if expanded == nil then
			for _, s in cx.session:sessions() do if tostring(s.id) == workspace then expanded = s.current; break end end
		end
		if not expanded and not use_host(cx,host_of(cx,"sessions",tonumber(workspace))) then return true end
		workspace_expanded[workspace] = not expanded
		tern.kv.set("workspace_expanded",workspace_expanded)
		refresh(cx)
		return true
	end
	if ev.act == "inbox" then cx:action("inbox"); return true end
	if ev.act == "clear-history" then
		-- Forgets closed agents only; live ones are recorded again by the next render.
		agent_history={}
		tern.kv.set("agent_history",agent_history)
		refresh(cx)
		return true
	end
	if ev.act == "settings" then settings_menu(cx); return true end
	if ev.act == "sidebar-width" then sidebar_width_menu(cx); return true end
	if ev.act == "switch-host" then
		local items = {}
		for _, host in cx.hosts:list() do
			table.insert(items,{label=host.name,detail=(if host.kind == "local" then "This Mac" else host.address or "Remote") .. " · " .. host.state,
				current=host.current,host=host.id,connected=host.state == "connected"})
		end
		if #items > 0 then
			cx:pick({items=items,placeholder="Switch Tern host · running tasks stay on their host",action="switch"}):next(function(item,err,nextCx)
				if err or not item or not nextCx then return end
				if not item.connected then nextCx:toast("info","Host is not connected","Reconnect or verify this host in Tern’s host controls."); return end
				nextCx.hosts:switch(item.host)
				refresh(nextCx)
			end)
		end
		return true
	end
	if ev.act == "usage" then
		read_usage(cx,true)
		local items = {}
		for _, q in quotas do
			table.insert(items,{label=q.provider .. " · " .. q.label .. " · " .. (if q.stale then "Updating…" else math.floor(q.remaining*100+0.5) .. "% left"),detail=usage.reset_countdown(q.reset_at,quota_epoch and (quota_epoch+tern.now()-quota_epoch_at)) or "Reset time not reported"})
		end
		if #items > 0 then cx:pick({items=items,placeholder="OMP provider limits · remaining quota"}) end
		return true
	end
	if ev.act == "edit-shortcuts" then
		local items = {}
		for i, item in shortcuts do
			table.insert(items, {label="Remove " .. item.label,group="Your shortcuts",remove=i})
		end
		for _, action in cx.actions:list() do
			if action.plugin and action.plugin ~= PLUGIN_ID and action.available then
				table.insert(items, {label=action.label, group=action.group, shortcut={label=action.label,icon="plug",action=action.id}})
			end
		end
		for _, block in cx.session:block_types() do
			if block.palette and string.sub(block.kind,1,5) ~= "tern." then
				table.insert(items,{label=block.title, group="Plugin blocks",shortcut={label=block.title,icon=block.icon,block=block.kind}})
			end
		end
		cx:pick({items=items,placeholder="Add a plugin shortcut, or remove one"}):next(function(item, _, nextCx)
			if not item then return end
			if item.remove then table.remove(shortcuts,item.remove)
			else
				for _, s in shortcuts do
					if s.action == item.shortcut.action and s.block == item.shortcut.block then return end
				end
				table.insert(shortcuts,item.shortcut)
			end
			tern.kv.set("shortcuts",shortcuts)
			refresh(nextCx)
		end)
		return true
	end
	local launch = tonumber(string.match(ev.act,"^launch:(%d+)$"))
	if launch then
		local shortcut = shortcuts[launch]
		if not shortcut then return true end
		local focused = cx.session:focused()
		if not use_host(cx,host_of(cx,"panes",focused)) then return true end
		if focused and owned[focused] then
			local tab = cx.session:tab_of(focused)
			for _, p in cx.session:panes() do
				if p.tab == tab and not owned[p.pane] then cx.layout:focus(p.pane); break end
			end
		end
		if shortcut.block then
			local pane = cx:new_block(shortcut.block,{},"glimpse")
			if not pane then cx:toast("info", "Enable " .. shortcut.label .. " in Tern Settings → Plugins") end
		else
			local available = false
			for _, action in cx.actions:list() do
				if action.id == shortcut.action and action.available then available = true; break end
			end
			if available then cx:action(shortcut.action)
			else cx:toast("info", "Enable " .. shortcut.label .. " in Tern Settings → Plugins") end
		end
		return true
	end
	if ev.act == "new-workspace" then
		local host = cx.hosts:current()
		local function create(path,nextCx)
			if type(path) ~= "string" or path == "" then return end
			if string.sub(path,1,1) ~= "/" then nextCx:toast("error","Use an absolute folder path"); return end
			if nextCx.hosts:current().id ~= host.id then nextCx:toast("info","Project not added","Switch back to " .. host.name .. " before choosing its folder."); return end
			local created=nextCx.sessions:create({name=string.match(path,"([^/]+)/*$"),cwd=path})
			if created then project_paths[string.format("%.0f",created.id)]=path;tern.kv.set("project_paths",project_paths) end
			refresh(nextCx)
		end
		if tern.runtime.os == "macos" and host.kind == "local" then
			tern.process.run({"/usr/bin/osascript","-e",'POSIX path of (choose folder with prompt "Choose a project folder for Switchboard")'},
				{timeout_ms=600000},function(result,nextCx)
					if result.status == 0 and nextCx then create(string.gsub(result.stdout,"[\r\n]+$",""),nextCx)
					elseif nextCx and not string.find(result.stderr or "","%-128") then nextCx:toast("error","Folder chooser unavailable",result.stderr) end
				end)
		else
			cx:prompt({placeholder="Project folder on " .. host.name .. " — absolute path"}):next(function(path,err,nextCx)
				if not err and nextCx then create(path,nextCx) end
			end)
		end
		return true
	end

	local session = tonumber(string.match(ev.act, "^session:(%d+)$"))
	if not session then return false end
	if use_host(cx,host_of(cx,"sessions",session)) then cx.sessions:switch(session) end
	refresh(cx)
	return true
end
tern.on("canvas_action", sidebar_action)
sidebar_route=function(link,cx)
 local kind,encoded=string.match(link.url,"^switchboard://sidebar/(%a+)/([%w_%-=]+)$")
 if not kind then return {handled=true} end
 local ok,payload=pcall(function() return tern.json.decode(tern.base64.decode(encoded)) end)
 if not ok or type(payload)~="table" or payload.pane~=link.pane then return {handled=true} end
 local info=cx.session:pane(payload.pane)
 if not info or info.block~="switchboard.sidebar" then return {handled=true} end
 if kind=="resize" then
  local sizes=section_sizes.normalize(payload.sizes)
  if sizes then
   tern.kv.set("section_sizes",sizes)
   refresh(cx)
  end
 elseif kind=="action" and type(payload.event)=="table" and type(payload.event.act)=="string" then
  local ev=payload.event
  ev.owner=PLUGIN_ID; ev.pane=payload.pane
  sidebar_action(ev,cx)
 end
 return {handled=true}
end

tern.on("window_start", function(cx)
	force_until = tern.now() + 3000
	-- A registered hook keeps the timer handle reachable across Lua collection.
	if clock or activity_clock or live_clock then refresh(cx) end
end)
local notified_at = {}
-- macOS notifications are for when Tern is in the background; the frontmost app is read with
-- lsappinfo (no permission prompt). Heuristic terminal agents pass a long cooldown because their
-- state is inferred from screen changes and can flip often.
local function notify_agent(cx, pane, reason, cooldown)
	if not enabled or tern.runtime.os ~= "macos" then return end
	local now = tern.now()
	local key = tostring(pane) .. ":" .. reason
	if notified_at[key] and now - notified_at[key] < (cooldown or 10000) then return end
	notified_at[key] = now
	local info = cx.session:pane(pane)
	local name = (info and info.title) or "Agent"
	local function escape(text)
		text = string.gsub(text, "\\", "\\\\")
		text = string.gsub(text, '"', '\\"')
		return text
	end
	local script = string.format('display notification "%s" with title "Switchboard" subtitle "%s"', escape(reason), escape(name))
	pcall(tern.process.run, {"/bin/sh", "-c", '/usr/bin/lsappinfo info -only bundleid "$(/usr/bin/lsappinfo front)"'}, {timeout_ms = 2000}, function(result)
		-- Fail open: if the lookup breaks, a notification beats silence.
		if result and result.status == 0 and string.find(result.stdout or "", "stencil.tern", 1, true) then return end
		pcall(tern.process.run, {"/usr/bin/osascript", "-e", script}, {timeout_ms = 3000}, function() end)
	end)
end

for _, event in {"focus", "pane_created", "pane_closed", "tab_created", "tab_closed", "agent_state", "agent_finished", "title", "cwd", "session_ended"} do
	tern.on(event, function(ev, cx)
		if event=="tab_closed" and next(closed_tabs_to_check)~=nil then
			if jump_clock then jump_clock:cancel();jump_clock=nil end
			if close_check then close_check:cancel();close_check=nil end
			enabled=true
			jump_after_close(cx)
		end
		if event=="agent_finished" then
			if ev.result == "done" or ev.result == "failed" then
				notify_agent(cx, ev.pane, if ev.result == "done" then "Finished" else "Failed")
			end
			completed_signals[ev.pane]=if ev.result=="done" or ev.result=="failed" then "idle" else "exited"
			status_reads[ev.pane]=nil
		elseif event=="agent_state" then
			if ev.new == "waiting_input" and ev.old ~= "waiting_input" then
				notify_agent(cx, ev.pane, "Needs your input")
			end
			completed_signals[ev.pane]=nil
			status_reads[ev.pane]=nil
		end
		if event == "focus" and cx.session:focused() ~= ev.pane then return end
		if event == "focus" and not owned[ev.pane] and (not navigation_intent or navigation_intent == ev.pane) then
			selected_content=ev.pane
			if navigation_intent == ev.pane then navigation_intent=nil end
			local tab=ev.tab or cx.session:tab_of(ev.pane)
			if tab then focused_by_tab[tab]=ev.pane end
		end

		if event == "pane_closed" then
			local agent_tab=known_agent_tabs[ev.pane]
			known_agent_tabs[ev.pane]=nil
			if agent_tab and (enabled or close_check~=nil) then
				closed_tabs_to_check[agent_tab]=true
				if jump_clock then jump_clock:cancel() end
				jump_clock=tern.timer(0,function(nextCx)jump_clock=nil;if nextCx then jump_after_close(nextCx) end end)
				local content=false
				for _,pane in cx.session:panes() do
					if pane.pane~=ev.pane and pane.tab==agent_tab and not owned[pane.pane] then content=true;break end
				end
				if not content then
					if jump_clock then jump_clock:cancel();jump_clock=nil end
					jump_after_close(cx)
				end
			end
			if navigation_intent==ev.pane then navigation_intent=nil end
			local closed_tab
			for tab,pane in pending do if pane==ev.pane then closed_tab=tab; break end end
			for tab, pane in pending do
				if pane == ev.pane then pending[tab] = nil; forget_pane(pane); is_canvas[pane]=nil end
			end
			if closed_tab and closing_empty_tabs[closed_tab] then
				closing_empty_tabs[closed_tab]=nil
			elseif closed_tab and enabled then
				close_check=tern.timer(100,function(nextCx)
					close_check=nil
					if not nextCx then return end
					local survives=false
					for _,tab in nextCx.session:tabs() do if tab.id==closed_tab then survives=true; break end end
					if survives and not closing_native_tabs[closed_tab] and not closed_tabs_to_check[closed_tab] then restore(nextCx)
					else
						closing_native_tabs[closed_tab]=nil
						enabled=true; closed_tabs_to_check[closed_tab]=true;jump_after_close(nextCx);refresh(nextCx)
					end
				end)
			end
		end
		-- Keep the timer handle rooted in a recurring registered hook.
		if clock then refresh(cx) end
	end)
end
local function poll(cx)
 clock = tern.timer(1500, poll)
 -- Re-assert the layout sheet every tick: Tern can drop plugin sheets on a reload and
 -- the native rail (212px panel offset) stays visible until one lands.
 if enabled then apply_navigation() end
	ready = true
	if cx and not enabled then
		discover(cx)
		if next(owned)~=nil then enabled=true;tern.kv.set("enabled",true) end
	end
	if cx and enabled then
		local focus=cx.session:focused()
		local tab=focus and cx.session:tab_of(focus)
		local content=false
		if focus and owned[focus] and tab then
			for _,pane in cx.session:panes() do if pane.tab==tab and not owned[pane.pane] then content=true;break end end
			if not content then closed_tabs_to_check[tab]=true;jump_after_close(cx) else refresh(cx,false) end
		else refresh(cx,false) end
		read_usage(cx)
		scan_terminals()
	end
end
local function activity_gap()
	for _, record in activity do
		if record.read_at == -math.huge then return 300 end
	end
	return 1500
end
local function poll_activity(cx)
	if cx and enabled then
		local infos=all_infos(cx)
		read_terminal_screens(cx,infos)
		sample(cx,infos,true)
		-- First sight has no snapshot; two reads per tick halve the burst
		-- without pushing one timer callback past its budget.
		for _, record in activity do
			if record.read_at == -math.huge then
				sample(cx,infos,true)
				break
			end
		end
		for _, n in terminal_notices do notify_agent(cx, n.pane, n.reason, 120000) end
		terminal_notices = {}
	end
	activity_clock=tern.timer(activity_gap(),poll_activity)
end
local function poll_live(cx)
 live_clock=tern.timer(1000,poll_live)
 if cx and enabled then read_native_subagents(cx) end
end
live_clock=tern.timer(500,poll_live)
activity_clock=tern.timer(300,poll_activity)
clock = tern.timer(200, poll)
