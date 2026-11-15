local M = {}

function M.clean_layout(tree, owned)
	if not tree then return nil end
	if tree.pane then return if owned[tree.pane] then nil else {pane=tree.pane} end
	local a, b = M.clean_layout(tree[1],owned), M.clean_layout(tree[2],owned)
	if not a then return b end
	if not b then return a end
	return {split=tree.split,ratio=tree.ratio or 0.5,[1]=a,[2]=b}
end

function M.build(sessions, tabs, panes, agents, owned, activity, layouts, focused_by_tab, hosts)
	local result = {projects={}, agents={}, running=0, waiting=0, block_details={}}
	local projects, tabIndex, paneIndex = {}, {}, {}
	local unowned_by_tab, working_tab = {}, {}
	local hostByPane,hostBySession={},{}
	for _,host in hosts or {} do
		for _,id in host.panes or {} do hostByPane[id]=host end
		for _,id in host.sessions or {} do hostBySession[id]=host end
	end
	for _, s in sessions do
		local project = {id=s.id, name=s.name, current=s.current == true, tabs={}, busy_tabs=0, host=hostBySession[s.id]}
		projects[s.id] = project
		table.insert(result.projects, project)
	end
	local agentIndex={}
	for _,a in agents do agentIndex[a.pane]=a end
	for _, p in panes do
		paneIndex[p.pane] = p
		if not owned[p.pane] then
			local agent=agentIndex[p.pane]
			local sample=activity and activity[p.pane]
			local snapshot=sample and sample.snapshot
			result.block_details[p.pane]={title=p.title,kind=p.kind,cwd=if agent then agent.cwd else p.cwd,
				command=p.running and p.running.line,last_command=p.last and p.last.line,last_exit=p.last and p.last.status,error=p.error,
				state=if agent then agent.state elseif p.busy then "working" else "idle",
				model=agent and agent.model,steps=snapshot and snapshot.steps or {},todo=snapshot and snapshot.todo}
			if p.tab ~= nil then
				unowned_by_tab[p.tab] = unowned_by_tab[p.tab] or {}
				table.insert(unowned_by_tab[p.tab], p)
			end
		end
	end
	for _, a in agents do
		local p = paneIndex[a.pane]
		if p and p.tab ~= nil and a.state == "working" then working_tab[p.tab] = true end
	end
	for _, t in tabs do
		tabIndex[t.id] = t
		local chosen = focused_by_tab and focused_by_tab[t.id]
		local pane = paneIndex[chosen or t.pane]
		local unowned = unowned_by_tab[t.id] or {}
		if not pane or pane.tab ~= t.id or owned[pane.pane] then
			pane = unowned[1] or pane
		end
		if pane and not owned[pane.pane] and projects[t.session] then
			local title = pane.title or t.title
			local program = string.match(pane.program or "", "([^/]+)$")
			if pane.kind ~= "agent" and pane.at_prompt and (program == "zsh" or program == "bash" or program == "fish" or program == "sh") then
				title = string.match(pane.cwd or "", "([^/]+)/*$") or title
			end
			local count, secondary, busy = #unowned, {}, t.busy == true or working_tab[t.id] == true
			for _, p in unowned do
				if p.pane ~= pane.pane then table.insert(secondary,p.title) end
				if p.busy then busy=true end
			end
			if busy then projects[t.session].busy_tabs += 1 end
			local arrangement = layouts and layouts[t.id]
			local floats = 0
			for _, f in (if arrangement then arrangement.floats else {}) or {} do
				if not owned[f.pane] then floats += 1 end
			end
			table.insert(projects[t.session].tabs, {
				id=t.id, pane=pane.pane,
				name=title, secondary=if #secondary>0 then table.concat(secondary,"  ·  ") else nil, busy=busy,
				pane_count=count, layout=M.clean_layout(arrangement and arrangement.root,owned), floats=floats,
			})
		end
	end
	for _, a in agents do
		if a.state ~= "exited" then
			local pane = paneIndex[a.pane]
			local tab = pane and tabIndex[pane.tab]
			local project = tab and projects[tab.session]
			local sample = activity and activity[a.pane]
			table.insert(result.agents, {
				synthetic=a.synthetic, harness=if a.synthetic then a.command else nil,
				pane=a.pane, host=hostByPane[a.pane] or (tab and hostBySession[tab.session]),cwd=a.cwd,
				delivery_error=if type(a.delivery_error)=="string" then a.delivery_error else nil,
				state=if a.state == "idle" and sample and sample.unseen then "done" else a.state,
				name=a.title or (if pane then pane.title else "Agent"),
				project=if project then project.name else (string.match(a.cwd or "", "([^/]+)/*$") or "Agent"),
				project_id=project and project.id,
				blocks=tab and M.clean_layout(layouts and layouts[tab.id] and layouts[tab.id].root,owned),
				model=if type(a.model) == "string" then a.model else nil,
				subagents=sample and sample.subagents or {},
				progress=sample and sample.snapshot, progress_completed_at=sample and sample.progress_completed_at, unavailable=sample and sample.unavailable,
				activity_status=if a.synthetic then "terminal" elseif not sample or sample.read_at==-math.huge then "loading"
					elseif sample.unavailable then "unavailable" elseif sample.empty_transcript then "unreported"
					elseif sample.snapshot and #sample.snapshot.steps==0 then "no_tools" else nil,
				updated_at=sample and sample.updated_at or 0, finished_at=sample and sample.finished_at or 0,
				finished=a.state=="idle" and ((sample and (sample.finished_at or 0)>0) or (sample and not sample.empty_transcript and sample.snapshot and (#sample.snapshot.steps>0 or sample.snapshot.response~=nil or sample.snapshot.todo~=nil))) or false,
				recent_order=sample and sample.recent_order or 0, observed_index=#result.agents+1,
			})
			if a.state == "working" then result.running += 1 end
			if a.state == "waiting_input" then result.waiting += 1 end
		end
	end
	table.sort(result.agents, function(a,b)
		local aa,ba=a.state=="waiting_input",b.state=="waiting_input"
		if aa~=ba then return aa end
		-- recent_order is assigned once, on first sight, so rows never move while
		-- the user reads or clicks them; only a new agent appends above or below.
		if a.recent_order~=b.recent_order then return a.recent_order>b.recent_order end
		return a.observed_index < b.observed_index
	end)
	return result
end

return M
