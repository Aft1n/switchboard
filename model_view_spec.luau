local model = require("./model")
local function eq(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local layout = model.clean_layout({split="right",ratio=0.2,[1]={pane=100},[2]={split="down",ratio=0.6,[1]={pane=101},[2]={pane=102}}},{[100]=true})
eq(layout.split, "down")
eq(layout[1].pane, 101)
eq(layout[2].pane, 102)
eq(model.clean_layout({pane=100},{[100]=true}), nil)
local data = model.build(
	{{id=1,name="api",current=true,tabs={10}}, {id=2,name="web",tabs={20}}},
	{{id=10,session=1,pane=101,title="Agent",panes=2}, {id=20,session=2,pane=201,name="Preview",title="shell"}},
	{{pane=100,tab=10,title="Switchboard"}, {pane=101,tab=10,title="Fix auth",cwd="/api"}, {pane=201,tab=20,title="Web",cwd="/web"}},
	{{pane=201,state="working",model="m",cwd="/web"}, {pane=101,state="idle",cwd="/api"}},
	{[100]=true}
)
eq(#data.projects, 2)
eq(data.projects[1].name, "api")
eq(data.projects[1].tabs[1].pane, 101)
eq(data.projects[1].tabs[1].name, "Fix auth")
eq(data.agents[1].pane, 201)
eq(data.agents[1].project, "web")
eq(data.agents[2].name, "Fix auth")
eq(data.running, 1)
eq(data.waiting, 0)
eq(#model.build({}, {}, {}, {}, {}).agents, 0)
local edge = model.build({}, {}, {}, {
	{pane=1,state="exited",cwd="/old"}, {pane=2,state="waiting_input",cwd="/project/",model={}},
}, {})
eq(#edge.agents, 1)
eq(edge.waiting, 1)
eq(edge.agents[1].project, "project")
eq(edge.agents[1].model, nil)
local view = require("./view")
local stub = {el=function(tag, props, children)
	assert(type(tag)=="string" and type(props)=="table")
	return {tag=tag,props=props,p=props,children=children}
end, node=function(kind,props,children) return {tag=kind,props=props,children=children} end}
stub.button = function(label,props) return {tag="button",props=props,p=props,children=nil} end
local tree = view.render(stub, data, 101)
local function collect(node, predicate, output)
	if predicate(node) then table.insert(output,node) end
	for _,child in node.children or {} do collect(child,predicate,output) end
end
local function has_class(node, class)
	return node.props and node.props.class and string.find(" " .. node.props.class .. " "," " .. class .. " ",1,true) ~= nil
end
local function class_nodes(root, class)
	local nodes = {}
	collect(root,function(node) return has_class(node,class) end,nodes)
	return nodes
end
local tabs = class_nodes(tree,"cp-tab")
eq(#tabs,1)
eq(tabs[1].props.actions.click,"pane:101")
local actions = {}
local function walk(node)
	if node.props and node.props.actions then actions[node.props.actions.click] = node end
	for _, child in node.children or {} do walk(child) end
end
walk(tree)
eq(#class_nodes(tree,"cp-subagent-branch"),0)
data.workspace_expanded={ ["1"]=false, ["2"]=true }
local folded = view.render(stub,data,101)
eq(#class_nodes(folded,"cp-tab"),1)
local folded_tab = class_nodes(folded,"cp-tab")[1]
eq(folded_tab.children[2].children[1].props.text,"Web")
eq(#class_nodes(folded,"cp-agent"),2)
local folded_actions = {}
collect(folded,function(node) return node.props and node.props.actions ~= nil end,folded_actions)
for _,node in folded_actions do actions[node.props.actions.click] = node end
eq(actions["fold-workspace:1"].props.attrs["aria-expanded"],"false")
eq(actions["fold-workspace:2"].props.attrs["aria-expanded"],"true")
data.workspace_expanded=nil

local empty_project_tree=view.render(stub,{
	projects={{id=42,name="empty",tabs={}}},agents={},running=0,waiting=0,quotas={},shortcuts={},
},101)
local empty_project=class_nodes(empty_project_tree,"cp-project")[1]
eq(empty_project.props.actions.click,"select-workspace:42")
eq(empty_project.props.title,"Select project · ⌘T to open a tab")
eq(empty_project.props.attrs["aria-current"],"false")
eq(empty_project.props.attrs["aria-expanded"],"false")

data.agents[1].progress={steps={{label="First",status="done"},{label="Second",status="done"},{label="Current",status="running"}},todo={done=2,total=5}}
data.agents[2].state="working"
data.agents[2].progress={steps={}}
local compact = view.render(stub,data,101)
local stepCount = 0
local function countSteps(node)
	if node.props and (node.props.class == "cp-step cp-step-running" or node.props.class == "cp-step cp-step-done") then stepCount += 1 end
	for _,child in node.children or {} do countSteps(child) end
end
countSteps(compact)
eq(stepCount,1)
local meters, activities = {}, {}
collect(compact,function(node) return node.tag == "meter" end,meters)
collect(compact,function(node) return node.tag == "progress" end,activities)
eq(#meters,1)
eq(meters[1].props.role,"switchboard.progress")
eq(#activities,0)
local compact_rows=class_nodes(compact,"cp-agent-progress")
eq(#compact_rows,1)
eq(#compact_rows[1].children,2)
eq(compact_rows[1].children[1].tag,"meter")
eq(has_class(compact_rows[1].children[2],"cp-progress-count"),true)
eq(compact_rows[1].children[2].props.text,"2 / 5")
eq(compact_rows[1].children[2].props.title,"2 of 5 tasks done")
local compact_card=class_nodes(compact,"cp-card-agent201")[1]
eq(#compact_card.children,4)
eq(has_class(compact_card.children[1],"cp-agent-top"),true)
eq(has_class(compact_card.children[2],"cp-agent-bottom"),true)
eq(has_class(compact_card.children[3],"cp-step"),true)
eq(has_class(compact_card.children[4],"cp-agent-progress"),true)
eq(#class_nodes(compact_card.children[4],"cp-step"),0)
eq(#class_nodes(class_nodes(compact,"cp-agent-bottom")[1],"cp-progress-count"),0)
local ordered = model.build({}, {}, {}, {
	{pane=1,title="Needs input",state="waiting_input"},
	{pane=2,title="Finished earlier",state="idle"},
	{pane=3,title="Finished last",state="idle"},
	{pane=4,title="Running",state="working"},
}, {}, {
	[1]={updated_at=1},[2]={finished_at=20},[3]={finished_at=30},[4]={updated_at=100},
})
eq(ordered.agents[1].pane,1)
eq(ordered.agents[2].pane,2)
eq(ordered.agents[3].pane,3)
eq(ordered.agents[4].pane,4)
actions = {}
local split
local function walk(node)
	if node.tag == "split" then split = node end
	if node.props and node.props.actions then actions[node.props.actions.click] = true end
	for _, child in node.children or {} do walk(child) end
end
walk(tree)
eq(split.tag,"split")
eq(split.props.key,"sections")
eq(split.props.role,"switchboard.sections")
eq(split.props.sizes[1],0.42)
eq(split.props.sizes[2],0.58)
eq(split.props.variant,nil)
eq(split.props.min[1],"6lines")
eq(split.props.min[2],"8lines")
local sections=class_nodes(tree,"cp-sections")
eq(#sections,1)
eq(#sections[1].children,1)
eq(#class_nodes(tree,"cp-section-divider"),0)
data.section_sizes={0.57,0.43}
local resized=view.render(stub,data,101)
local resized_split
local function find_split(node)
	if node.tag == "split" then resized_split = node end
	for _, child in node.children or {} do find_split(child) end
end
find_split(resized)
eq(resized_split.props.sizes[1],0.57)
eq(resized_split.props.sizes[2],0.43)
data.section_sizes=nil
eq(actions["session:1"], nil)
eq(actions["session:2"], nil)
eq(actions["fold-workspace:1"], true)
eq(actions["fold-workspace:2"], true)
eq(actions["pane:101"], true)
eq(actions["pane:201"], true)
eq(actions["close-tab:10"], true)
eq(actions["restore"], true)
eq(actions["new-workspace"], true)
local visible_tab_rows=class_nodes(tree,"cp-tab-row")
eq(#visible_tab_rows,1)
eq(visible_tab_rows[1].props.key,"tab:10")
eq(#visible_tab_rows[1].children,2)
eq(visible_tab_rows[1].children[2].props.title,"Close tab")
eq(visible_tab_rows[1].children[2].props.aria,"Close Fix auth")
eq(visible_tab_rows[1].children[2].props.key,"close-tab10")
data.quotas={{provider="anthropic",label="7 Day",remaining=0.01},{provider="openai-codex",label="5 hours",remaining=0.06}}
local limited=view.render(stub,data,101)
eq(#class_nodes(limited,"cp-quota"),2)
eq(#class_nodes(limited,"cp-ring-segment"),0)
eq(#class_nodes(limited,"cp-limit-alert"),2)
eq(#class_nodes(limited,"cp-quota-popover"),2)
data.host={name="Local",kind="local",state="connected"}
local hosted=view.render(stub,data,101)
eq(#class_nodes(hosted,"cp-host"),1)
eq(#class_nodes(hosted,"cp-project"),2)
local two = model.build({{id=1,name="Project",current=true}},{{id=10,session=1,pane=1,name="Old tab name"}}, {
	{pane=1,tab=10,title="Implement auth"},{pane=2,tab=10,title="API server"},{pane=99,tab=10,title="Switchboard"},
},{{pane=1,state="working"}}, {[99]=true},{},{},{[10]=2})
eq(two.projects[1].tabs[1].name,"API server")
eq(two.projects[1].tabs[1].secondary,"Implement auth")
eq(two.projects[1].busy_tabs,1)
eq(two.projects[1].tabs[1].pane_count,2)
local two_view=view.render(stub,two,2)
eq(#class_nodes(two_view,"cp-tab-secondary"),1)
eq(#class_nodes(two_view,"cp-pane-count"),0)
eq(#class_nodes(two_view,"cp-workspace-busy"),1)
eq(two.block_details[1].title,"Implement auth")
eq(two.block_details[1].state,"working")
eq(two.block_details[2].title,"API server")
eq(two.block_details[99],nil)
for _,card in class_nodes(compact,"cp-agent") do assert(type(card.props.title)=="string") end
print("Switchboard model checks passed")

local remotePane=4521191813414916
local hosts={
 {id=0,name="This Mac",kind="local",state="connected",panes={4},sessions={1}},
 {id=1,name="build-worker",kind="remote",address="dev@build-worker",state="connected",panes={remotePane},sessions={22}},
}
local mixed=model.build({{id=1,name="API"},{id=22,name="API"}},
 {{id=10,session=1,pane=4},{id=30,session=22,pane=remotePane}},
 {{pane=4,tab=10,title="Local task",cwd="/api",kind="agent"},{pane=remotePane,tab=30,title="Remote task",cwd="/srv/api",kind="agent"}},
 {{pane=4,state="working",cwd="/api"},{pane=remotePane,state="waiting_input",cwd="/srv/api"}}, {},{},nil,nil,hosts)
eq(#mixed.agents,2)
eq(mixed.agents[1].host.name,"build-worker")
eq(mixed.agents[1].host.kind,"remote")
eq(mixed.agents[2].host.kind,"local")
eq(mixed.block_details[remotePane].cwd,"/srv/api")
local mixedTree=view.render(stub,mixed,4)
local cards=class_nodes(mixedTree,"cp-agent")
eq(cards[1].props.actions.click,"pane:4521191813414916")
eq(#class_nodes(mixedTree,"cp-agent-host-remote"),1)
eq(#class_nodes(mixedTree,"cp-agent-host-local"),1)
local scoped=table.clone(mixed)
scoped.host=hosts[1]
local scoped_tree=view.render(stub,scoped,4)
eq(#class_nodes(scoped_tree,"cp-project"),1)
eq(#class_nodes(scoped_tree,"cp-agent"),2)
eq(#class_nodes(scoped_tree,"cp-agent-host-remote"),1)
for _,card in cards do assert(type(card.props.title)=="string") end
print("mixed host navigation checks passed")

local recent=model.build({}, {}, {}, {
 {pane=4521191813414916,state="idle"}, {pane=22,state="idle"}, {pane=23,state="working"}, {pane=24,state="waiting_input"},
}, {}, {
 [4521191813414916]={recent_order=2,finished_at=200},[22]={recent_order=4},[23]={recent_order=3},[24]={recent_order=1},
})
eq(recent.agents[1].pane,24)
eq(recent.agents[2].pane,22)
eq(recent.agents[3].pane,23)
eq(recent.agents[4].pane,4521191813414916)
print("cross-host recency checks passed")

eq(#class_nodes(mixedTree,"cp-agent-popovers"),0)
assert(string.find(cards[1].props.title,"build-worker",1,true))
print("native agent tooltip checks passed")

-- Closed chats reopen only when they carry a session; sessionless history stays inert.
local closedTree=view.render(stub,{
	projects={},agents={},running=0,waiting=0,closed={
		{session="s1",name="Old chat",pane=7,cwd="/api"},
		{name="Pinned old",pane=8,cwd="/web"},
	},
},101)
local closed_cards=class_nodes(closedTree,"cp-agent")
eq(#closed_cards,2)
eq(closed_cards[1].tag,"button")
eq(closed_cards[1].props.actions.click,"resume-session:s1")
eq(closed_cards[1].props.key,"closed:s1")
eq(closed_cards[2].tag,"div")
eq(closed_cards[2].props.actions,nil)
assert(string.find(closed_cards[1].props.title,"Click to reopen session",1,true))
assert(string.find(closed_cards[1].props.aria,"Click to reopen session",1,true))
assert(not string.find(closed_cards[2].props.title,"Click to reopen session",1,true))
eq(#class_nodes(closed_cards[1],"cp-state"),1)
eq(#class_nodes(closedTree,"cp-resumable"),1)
print("closed session reopen checks passed")

data.quotas[1].stale=true
local staleLimits=view.render(stub,data,101)
eq(#class_nodes(staleLimits,"cp-limit-alert"),1)
local values=class_nodes(staleLimits,"cp-quota-percent")
eq(values[1].props.text,"Updating…")
print("stale quota readings do not show depletion alerts")

eq(class_nodes(two_view,"cp-tab")[1].props.key,"tab10")
eq(class_nodes(two_view,"cp-tab-row")[1].props.key,"tab:10")
local original=data.projects[1].tabs[1]
local oldPane=original.pane
original.pane=999
local changedFocus=view.render(stub,data,999)
original.pane=oldPane
local focusTab=class_nodes(changedFocus,"cp-tab")[1]
eq(focusTab.props.key,"tab" .. tostring(original.id))
eq(class_nodes(changedFocus,"cp-tab-row")[1].props.key,"tab:" .. tostring(original.id))
print("workspace rows retain identity when their focused block changes")

local finished_data={
	projects={},agents={{pane=901,state="idle",finished_at=123,name="Finished agent",project="api",progress={steps={}}}},
	running=0,waiting=0,quotas={},shortcuts={},
}
local finished_tree=view.render(stub,finished_data,901)
local finished_card=class_nodes(finished_tree,"cp-card-agent901")[1]
local finished_status=class_nodes(finished_card,"cp-agent-status")[1]
eq(class_nodes(finished_status,"cp-state")[1].props.text,"Finished")
eq(#class_nodes(finished_tree,"cp-progress-count"),0)
local function count_kind(node, kind)
	local count=if node.tag==kind then 1 else 0
	for _,child in node.children or {} do count+=count_kind(child,kind) end
	return count
end
eq(count_kind(finished_card,"meter"),0)
print("finished agents do not imply task progress")

local countdown_data=table.clone(data)
countdown_data.quota_now=1000000
countdown_data.quotas={{provider="anthropic",label="5 hours",remaining=1,reset_at=3520000,detail="old absolute time"}}
local countdown_tree=view.render(stub,countdown_data,101)
eq(class_nodes(countdown_tree,"cp-quota-reset")[1].props.text,"Resets in 42m")
countdown_data.quota_now+=60000
countdown_tree=view.render(stub,countdown_data,101)
eq(class_nodes(countdown_tree,"cp-quota-reset")[1].props.text,"Resets in 41m")
print("quota hover countdown advances without a new provider report")

local child_data=table.clone(finished_data)
child_data.agents={{pane=901,name="Parent",state="idle",project="api",progress={steps={}},subagents={
 {id="child/a",title="Review",state="working",model="luna",step="Reading files"},
 {id="child-b",title="Checks",state="done",pane=902},
 {id="child-c",title="Waiting",state="idle"},
 {id="child-d",title="Broken",state="failed",error="Timeout"},
 {id="child-q",title="Queued ghost",state="queued"},
}}}
local collapsed_children=view.render(stub,child_data,901)
eq(#class_nodes(collapsed_children,"cp-subagent-toggle"),1)
local collapsed_toggle=class_nodes(collapsed_children,"cp-subagent-toggle")[1]
eq(collapsed_toggle.props.title,"Show 5 subagents")
eq(collapsed_toggle.props.aria,"Show 5 subagents for Parent")
eq(collapsed_toggle.children[1].props.text,nil)
eq(has_class(collapsed_toggle.children[1],"cp-subagent-bot"),true)
eq(collapsed_toggle.children[2].props.text,"5 · 1 running")
eq(has_class(collapsed_toggle.children[2],"cp-subagent-label"),true)
eq(has_class(collapsed_toggle.children[3],"cp-subagent-chevron"),true)
-- Children always render; CSS hides them until the toggle is open.
eq(has_class(collapsed_toggle,"cp-subagent-open"),false)
eq(#class_nodes(collapsed_children,"cp-subagent-card"),5)
local collapsed_rows=class_nodes(collapsed_children,"cp-agent-parent-row")
eq(#collapsed_rows,1)
eq(#collapsed_rows[1].children,2)
eq(has_class(collapsed_rows[1].children[1],"cp-agent"),true)
eq(has_class(collapsed_rows[1].children[2],"cp-subagent-branch"),true)
eq(#collapsed_rows[1].children[2].children,2)
eq(has_class(collapsed_rows[1].children[2].children[1],"cp-subagent-toggle"),true)
child_data.subagents_expanded={["901"]=true}
local expanded_children=view.render(stub,child_data,901)
eq(class_nodes(expanded_children,"cp-subagent-label")[1].props.text,"5 · 1 running")
local expanded_toggle=class_nodes(expanded_children,"cp-subagent-toggle")[1]
eq(expanded_toggle.children[1].props.text,nil)
eq(has_class(expanded_toggle.children[1],"cp-subagent-bot"),true)
eq(expanded_toggle.children[2].props.text,"5 · 1 running")
eq(has_class(expanded_toggle.children[2],"cp-subagent-label"),true)
eq(has_class(expanded_toggle.children[3],"cp-subagent-chevron"),true)
local children=class_nodes(expanded_children,"cp-subagent-card")
eq(#children,5)
eq(children[1].props.actions.click,"subagent:901:child%2Fa")
eq(children[2].props.actions.click,"pane:902")
local expanded_rows=class_nodes(expanded_children,"cp-agent-parent-row")
eq(#expanded_rows,1)
eq(#expanded_rows[1].children,2)
eq(has_class(expanded_rows[1].children[1],"cp-agent"),true)
eq(has_class(expanded_rows[1].children[2],"cp-subagent-branch"),true)
eq(#expanded_rows[1].children[2].children,2)
eq(has_class(expanded_rows[1].children[2].children[1],"cp-subagent-toggle"),true)
eq(has_class(expanded_rows[1].children[2].children[2],"cp-subagents"),true)
eq(#class_nodes(expanded_rows[1].children[2].children[2],"cp-subagent-card"),5)
-- Working and done children stay full-strength; idle, failed and queued history are dimmed.
for index, muted_class in {false,false,true,true,true} do
 eq(has_class(children[index],"cp-subagent-muted"),muted_class)
end
local muted_cards=class_nodes(expanded_children,"cp-subagent-muted")
eq(#muted_cards,3)
eq(muted_cards[1],children[3])
eq(muted_cards[2],children[4])
eq(muted_cards[3],children[5])
-- Spawn-only queued children show as closed history: not clickable, with a Closed pill.
local closed_card=children[5]
eq(closed_card.tag,"div")
eq(closed_card.props.actions,nil)
eq(class_nodes(closed_card,"cp-subagent-name")[1].props.text,"Queued ghost")
local closed_pill=class_nodes(closed_card,"cp-subagent-state-closed")[1]
eq(closed_pill.props.text,"Closed")

local queued_data=table.clone(finished_data)
queued_data.subagents_expanded={["906"]=true}
queued_data.agents={{pane=906,name="Queued parent",state="working",project="api",progress={steps={},todo={done=0,total=2}},subagents={
 {id="child-q1",title="Queued one",state="queued"},
 {id="child-q2",title="Queued two",state="queued"},
}}}
local queued_tree=view.render(stub,queued_data,906)
eq(#class_nodes(queued_tree,"cp-subagent-toggle"),1)
local queued_toggle=class_nodes(queued_tree,"cp-subagent-toggle")[1]
eq(queued_toggle.props.title,"Hide 2 subagents")
eq(queued_toggle.props.aria,"Hide 2 subagents for Queued parent")
eq(queued_toggle.children[1].props.text,nil)
eq(has_class(queued_toggle.children[1],"cp-subagent-bot"),true)
eq(queued_toggle.children[2].props.text,"2")
eq(has_class(queued_toggle.children[2],"cp-subagent-label"),true)
eq(string.find(queued_toggle.children[2].props.text,"running",1,true),nil)
eq(has_class(queued_toggle.children[3],"cp-subagent-chevron"),true)
local queued_cards=class_nodes(queued_tree,"cp-subagent-card")
eq(#queued_cards,2)
for _,card in queued_cards do
 eq(has_class(card,"cp-subagent-muted"),true)
 eq(card.props.actions,nil)
 eq(class_nodes(card,"cp-subagent-state-closed")[1].props.text,"Closed")
end
-- The todo meter is one row: the bar, then the count at its right end.
local queued_wrappers=class_nodes(queued_tree,"cp-agent-progress")
eq(#queued_wrappers,1)
eq(#queued_wrappers[1].children,2)
eq(queued_wrappers[1].children[1].tag,"meter")
eq(has_class(queued_wrappers[1].children[2],"cp-progress-count"),true)
eq(queued_wrappers[1].children[2].props.text,"0 / 2")
eq(count_kind(class_nodes(queued_tree,"cp-card-agent906")[1],"meter"),1)
local function no_nested_buttons(node,in_button)
 assert(not (in_button and node.tag=="button"),"nested button")
 for _,child in node.children or {} do no_nested_buttons(child,in_button or node.tag=="button") end
end
no_nested_buttons(expanded_children,false)
child_data.agents[1].progress={steps={},todo={done=1,total=3}}
local progress_children=view.render(stub,child_data,901)
local progress_wrappers=class_nodes(progress_children,"cp-agent-progress")
eq(#progress_wrappers,1)
eq(#progress_wrappers[1].children,2)
eq(progress_wrappers[1].children[1].tag,"meter")
eq(progress_wrappers[1].children[1].props.role,"switchboard.progress")
eq(has_class(progress_wrappers[1].children[2],"cp-progress-count"),true)
eq(progress_wrappers[1].children[2].props.text,"1 / 3")
local foot_data=table.clone(finished_data)
foot_data.subagents_expanded={["905"]=true}
foot_data.agents={{pane=905,name="Parent without todo",state="idle",project="api",progress={steps={}},subagents={
 {id="child-foot",title="Child",state="working"},
}}}
local foot_tree=view.render(stub,foot_data,905)
local foot_card=class_nodes(foot_tree,"cp-card-agent905")[1]
assert(foot_card,"missing agent card")
eq(#foot_card.children,2)
eq(has_class(foot_card.children[1],"cp-agent-top"),true)
eq(has_class(foot_card.children[2],"cp-agent-bottom"),true)
eq(#class_nodes(foot_card,"cp-agent-progress"),0)
local foot_head=class_nodes(foot_tree,"cp-agent-parent-row")[1]
eq(has_class(foot_head.children[2],"cp-subagent-branch"),true)
eq(foot_head.children[2].children[1].props.actions.click,"subagents:905")
local foot_step_data=table.clone(foot_data)
foot_step_data.agents[1].progress={steps={{label="Task row step",status="running"}}}
local foot_step_tree=view.render(stub,foot_step_data,905)
local foot_step_card=class_nodes(foot_step_tree,"cp-card-agent905")[1]
eq(#foot_step_card.children,3)
eq(has_class(foot_step_card.children[1],"cp-agent-top"),true)
eq(has_class(foot_step_card.children[2],"cp-agent-bottom"),true)
eq(has_class(foot_step_card.children[3],"cp-step"),true)
eq(#class_nodes(foot_step_card,"cp-agent-progress"),0)
eq(class_nodes(foot_step_card,"cp-step-label")[1].props.text,"Task row step")
print("subagent disclosure preserves navigation and avoids nested buttons")

-- A parent with subagents keeps its completed todo meter past the ten-minute hide; a parent without them does not.
local function completed_parent(pane,subagents)
	return {pane=pane,name="Parent",project="api",state="idle",finished_at=123,progress_completed_at=100,
		progress={steps={{label="Last step",status="done"}},todo={done=3,total=3}},subagents=subagents}
end
local bypass_data=table.clone(finished_data)
bypass_data.now=700000
bypass_data.subagents_expanded={["907"]=true}
bypass_data.agents={completed_parent(907,{
	{id="c1",title="Done child",state="done"},
	{id="c2",title="Closed child",state="queued"},
})}
local bypass_tree=view.render(stub,bypass_data,907)
local bypass_card=class_nodes(bypass_tree,"cp-card-agent907")[1]
assert(bypass_card,"missing agent card")
local bypass_wrappers=class_nodes(bypass_tree,"cp-agent-progress")
eq(#bypass_wrappers,1)
eq(#bypass_wrappers[1].children,2)
eq(bypass_wrappers[1].children[1].tag,"meter")
eq(bypass_wrappers[1].children[1].props.role,"switchboard.progress")
eq(bypass_wrappers[1].children[1].props.value,1)
local bypass_counts=class_nodes(bypass_tree,"cp-progress-count")
eq(#bypass_counts,1)
eq(bypass_counts[1].props.text,"3 / 3")
local bypass_steps=class_nodes(bypass_card,"cp-step")
eq(#bypass_steps,1)
eq(class_nodes(bypass_card,"cp-step-label")[1].props.text,"Last step")
eq(count_kind(bypass_card,"meter"),1)
eq(#class_nodes(bypass_tree,"cp-subagent-card"),2)
local bare_data=table.clone(finished_data)
bare_data.now=700000
bare_data.agents={completed_parent(908,{})}
local bare_tree=view.render(stub,bare_data,908)
local bare_card=class_nodes(bare_tree,"cp-card-agent908")[1]
assert(bare_card,"missing agent card")
eq(#class_nodes(bare_tree,"cp-agent-progress"),0)
eq(count_kind(bare_card,"meter"),0)
eq(class_nodes(bare_card,"cp-step-label")[1].props.text,"Last step")
print("completed subagent parents keep their todo meter past the time hide")
local harness_data=table.clone(foot_data)
harness_data.subagents_expanded={}
harness_data.agents={
 {pane=910,name="Fix",state="idle",project="api",harness="claude",synthetic=true,subagents={}},
 {pane=911,name="Fix",state="idle",project="api",harness="pi",synthetic=true,subagents={}},
 {pane=912,name="Fix",state="idle",project="api",subagents={}},
}
local harness_tree=view.render(stub,harness_data,910)
eq(#class_nodes(harness_tree,"cp-harness"),2)
eq(#class_nodes(class_nodes(harness_tree,"cp-card-agent912")[1],"cp-harness"),0)
print("harness agents show their icon before the title; omp rows do not")
-- The sidebar block patches by key: every rebuilt slot must be the key of exactly one tree node.
local slot_data=table.clone(child_data)
slot_data.projects=data.projects
slot_data.workspace_expanded={["1"]=true,["2"]=true}
slot_data.closed={{session="s9",name="Old",project="api"}}
local slot_cache=require("./render_cache").new(64)
slot_cache.begin()
local slot_tree=view.render(stub,slot_data,901,slot_cache)
local keyed_nodes={}
collect(slot_tree,function(node) return node.props~=nil and node.props.key~=nil end,keyed_nodes)
local key_count={}
for _,node in keyed_nodes do key_count[node.props.key]=(key_count[node.props.key] or 0)+1 end
for _,slot in {"ws:1","ws:2","tab:10","tab:20","agent:901","closed:s9","summary:"} do eq(key_count[slot],1) end
for _,slot in slot_cache.changed() do eq(key_count[slot],1) end
print("cached cards carry their slot key, so sidebar patches match")
-- Each tern.ui call costs milliseconds in Tern: a repaint with nothing changed must build no nodes,
-- and any shell input that moves must still show.
local calls=0
local counting={
 el=function(...) calls+=1; return stub.el(...) end,
 node=function(...) calls+=1; return stub.node(...) end,
 button=function(...) calls+=1; return stub.button(...) end,
}
local memo_data=table.clone(slot_data)
memo_data.host={id=1,kind="local",state="connected",name="Mac"}
memo_data.shortcuts={{icon="plug",label="One"}}
local memo_cache=require("./render_cache").new(64)
memo_cache.begin()
local memo_first,memo_sheet=view.render(counting,memo_data,901,memo_cache)
assert(calls>0,"first render builds nodes")
calls=0
memo_cache.begin()
local memo_again,memo_sheet_again=view.render(counting,memo_data,901,memo_cache)
eq(calls,0)
assert(memo_again==memo_first,"an unchanged repaint reuses the tree")
eq(memo_sheet_again,memo_sheet)
local memo_prev=memo_first
local function shell_changes(label,mutate)
 mutate()
 memo_cache.begin()
 local memo_tree=view.render(counting,memo_data,901,memo_cache)
 assert(memo_tree~=memo_prev,label .. " must rebuild the shell")
 memo_prev=memo_tree
end
shell_changes("host state",function() memo_data.host.state="offline" end)
shell_changes("shortcuts",function() memo_data.shortcuts={{icon="plug",label="Two"}} end)
shell_changes("quota state",function() memo_data.quota_state="Refreshing" end)
shell_changes("section sizes",function() memo_data.section_sizes={0.3,0.7} end)
shell_changes("closed list hidden",function() memo_data.sidebar_settings={closed=false} end)
shell_changes("agent gone",function() memo_data.agents={} end)
shell_changes("inbox count",function() memo_data.inbox_count=1 end)
shell_changes("update ready",function() memo_data.update_ready=true end)
print("an unchanged repaint builds no nodes; changed shell inputs still rebuild")
-- The bell carries Tern's inbox count; a downloaded update shows as a header icon.
local bell=class_nodes(memo_prev,"cp-bell")[1]
assert(bell,"missing inbox bell")
eq(#class_nodes(bell,"cp-bell-badge"),1)
eq(class_nodes(bell,"cp-bell-badge")[1].props.text,"1")
local update_nodes={}
collect(memo_prev,function(node) return node.props~=nil and node.props.actions~=nil and node.props.actions.click=="update" end,update_nodes)
eq(#update_nodes,1)
eq(#class_nodes(memo_prev,"cp-update"),1)
local no_update=table.clone(memo_data)
no_update.update_ready=false
local plain_tree=view.render(stub,no_update,901,nil)
eq(#class_nodes(plain_tree,"cp-update"),0)
eq(#class_nodes(plain_tree,"cp-bell-badge"),1)
print("bell badge and update icon follow the data")
-- Custom plugin shortcuts scroll in the row; built-ins live in a separate grid card, and add has its own slot.
local launch_data=table.clone(memo_data)
launch_data.native_blocks={
	{action="new_task_manager_block",group="Work",label="Task manager",icon="list-checks"},
	{action="new_browser_block",group="Surfaces",label="Browser",icon="globe"},
	{action="new_notebook",group="Data",label="Notebook",icon="file"},
}
launch_data.shortcuts={
	{label="Task board",icon="check",block="taskboard.board"},
	{label="Git pinned",icon="branch",action="new_git_block"},
}
local launch_tree=view.render(stub,launch_data,901,nil)
local scroll=class_nodes(launch_tree,"cp-launchers-scroll")[1]
assert(scroll,"missing launcher scroller")
local launched={}
collect(scroll,function(node)
	return node.props~=nil and node.props.actions~=nil and type(node.props.actions.click)=="string"
		and string.find(node.props.actions.click,"^launch:")~=nil
end,launched)
eq(#launched,2)
local card=class_nodes(launch_tree,"cp-launcher-card")[1]
assert(card,"missing launcher card")
local tiles={}
collect(card,function(node)
	return node.props~=nil and node.props.actions~=nil and type(node.props.actions.click)=="string"
		and string.find(node.props.actions.click,"^launch%-native:")~=nil
end,tiles)
eq(#tiles,3)
eq(#class_nodes(card,"cp-launcher-tile"),3)
eq(#class_nodes(card,"cp-launcher-group"),3)
local group_titles={}
collect(card,function(node) return node.props~=nil and node.props.class=="cp-launcher-group-title" end,group_titles)
eq(#group_titles,3)
eq(group_titles[1].props.text,"Work")
eq(group_titles[2].props.text,"Surfaces")
eq(group_titles[3].props.text,"Data")
eq(#class_nodes(launch_tree,"cp-launcher-grid-trigger"),1)
eq(#class_nodes(launch_tree,"cp-launcher-divider"),2)
local grid_inside=0
collect(scroll,function(node) if node.props~=nil and node.props.class~=nil and string.find(node.props.class,"cp-launcher-grid-trigger",1,true) then grid_inside+=1 end end,{})
eq(grid_inside,0)
local add_nodes={}
collect(launch_tree,function(node) return node.props~=nil and node.props.actions~=nil and node.props.actions.click=="edit-shortcuts" end,add_nodes)
eq(#add_nodes,1)
local add_inside=0
collect(scroll,function(node) if node.props~=nil and node.props.actions~=nil and node.props.actions.click=="edit-shortcuts" then add_inside+=1 end end,{})
eq(add_inside,0)
print("custom shortcuts scroll; built-ins are a separate grid card; add is its own slot")
-- Parked panes: a workspace with parked blocks gets a count badge and a hover card of unpark rows.
local park_data=table.clone(slot_data)
park_data.parked={
	["1"]={
		{pane=71,title="Processes",kind="procs",cwd="/api"},
		{pane=72,title="Git",kind="git",cwd="/api"},
	},
}
local park_tree,park_sheet=view.render(stub,park_data,901,nil)
local park_badges=class_nodes(park_tree,"cp-workspace-park")
eq(#park_badges,1)
eq(class_nodes(park_badges[1],"cp-park-count")[1].props.text,"2")
eq(park_badges[1].props.title,"2 parked panes in api")
eq(park_badges[1].props.actions.click,"park-open:1")
local park_cards=class_nodes(park_tree,"cp-park-card")
eq(#park_cards,1)
eq(#class_nodes(park_cards[1],"cp-park-title-count"),1)
local park_rows={}
collect(park_cards[1],function(node) return node.props~=nil and node.props.actions~=nil and type(node.props.actions.click)=="string" and string.find(node.props.actions.click,"^unpark:")~=nil end,park_rows)
eq(#park_rows,2)
eq(park_rows[1].props.actions.click,"unpark:71:1")
-- Rich row: title and a kind/folder line, like an agent card.
eq(class_nodes(park_rows[1],"cp-park-name")[1].props.text,"Processes")
eq(class_nodes(park_rows[1],"cp-park-meta")[1].props.text,"Task manager · api")
assert(string.find(park_sheet,".cp-park-card-1",1,true),"park card style is generated per workspace")
assert(string.find(park_sheet,".cp-park-1:hover",1,true),"the badge opens its card on hover")
park_data.park_open="1"
local pinned=view.render(stub,park_data,901,nil)
local pinned_card=class_nodes(pinned,"cp-park-card")[1]
assert(has_class(pinned_card,"cp-park-open"),"a click pins the card open")
local no_park=view.render(stub,memo_data,901,nil)
eq(#class_nodes(no_park,"cp-workspace-park"),0)
print("parked panes show per workspace")
-- A tree restored from history: the workspaces section offers the saved projects.
local restore_data=table.clone(slot_data)
restore_data.restore_tree=3
restore_data.restore_tabs=5
local restore_tree=view.render(stub,restore_data,901,nil)
local restore=class_nodes(restore_tree,"cp-restore-tree")[1]
assert(restore,"missing saved-tree restore button")
eq(restore.props.actions.click,"restore-tree")
eq(class_nodes(restore,"cp-restore-label")[1].props.text,"Restore saved tree")
eq(class_nodes(restore,"cp-restore-sub")[1].props.text,"3 projects · 5 agent tabs kept")
eq(#class_nodes(slot_tree,"cp-restore-tree"),0)
print("saved tree restore button follows the history")


-- Agent cards close their tab with a sibling x, never a button nested in the card button.
local close_nodes={}
collect(slot_tree,function(node) return node.props~=nil and node.props.actions~=nil and node.props.actions.click=="close-agent:901" end,close_nodes)
eq(#close_nodes,1)
local agent_rows=class_nodes(slot_tree,"cp-agent-row")
-- One row for the live card and one for the closed record's pin.
eq(#agent_rows,2)
eq(#class_nodes(class_nodes(agent_rows[1],"cp-card-agent901")[1],"cp-agent-row"),0)
eq(#class_nodes(class_nodes(agent_rows[1],"cp-card-agent901")[1],"cp-agent-parent-row"),0)
print("agent cards carry a sibling close button")
-- The header pin toggle opens a board; closed cards pin from their own hover control.
local unpinned_tree=view.render(stub,slot_data,901,nil)
eq(#class_nodes(unpinned_tree,"cp-pins"),0)
local pin_toggles=class_nodes(unpinned_tree,"cp-pins-toggle")
eq(#pin_toggles,1)
eq(pin_toggles[1].props.actions.click,"toggle-pins")
eq(#class_nodes(pin_toggles[1],"cp-pin-count"),0)
eq(pin_toggles[1].props.title,"Pinned agents · none yet")
-- Header order: count, pin, broom, bell.
local header_tools=class_nodes(unpinned_tree,"cp-agent-header-tools")[1]
eq(#header_tools.children,4)
eq(has_class(header_tools.children[1],"cp-count"),true)
eq(has_class(header_tools.children[2],"cp-pins-toggle"),true)
eq(has_class(header_tools.children[3],"cp-broom"),true)
eq(has_class(header_tools.children[4],"cp-bell"),true)
-- The board is always in the DOM (hover reveals it) but not persistently open.
eq(#class_nodes(unpinned_tree,"cp-pin-board"),1)
eq(has_class(class_nodes(unpinned_tree,"cp-pin-board")[1],"cp-pin-board-open"),false)
eq(class_nodes(unpinned_tree,"cp-pin-board-empty")[1].props.text,"No pinned agents\nPin an agent from its card.")
local closed_rows=class_nodes(unpinned_tree,"cp-closed-row")
eq(#closed_rows,1)
-- The closed card is the wrapper's first child; the pin sits beside it, right-aligned by CSS.
eq(#closed_rows[1].children,2)
eq(closed_rows[1].children[1].props.key,"closed:s9")
local closed_pin=closed_rows[1].children[2]
eq(closed_pin.props.role,"switchboard.closed-pin")
eq(closed_pin.props.actions.click,"pin-closed:s:s9")
eq(closed_pin.props.key,"pin-closed:s9")
eq(closed_pin.props.title,"Pin Old")
local pin_data=table.clone(finished_data)
pin_data.project_colors={api=2}
pin_data.agents={{pane=901,name="Parent",state="working",project="api",progress={steps={}},subagents={},pinned=true}}
pin_data.pinned={
	{at=11,pane=901,name="Parent",project="api",cwd="/api",session="s1",live=true},
	{at=12,pane=902,name="Old chat",project="api",cwd="/api/oldwork",session="s2",live=false},
}
local closed_board_tree=view.render(stub,pin_data,901,nil)
local hidden_board=class_nodes(closed_board_tree,"cp-pin-board")[1]
assert(hidden_board,"the board is present even when closed")
eq(has_class(hidden_board,"cp-pin-board-open"),false)
eq(#class_nodes(hidden_board,"cp-pin-card-item"),2)
local badge_toggle=class_nodes(closed_board_tree,"cp-pins-toggle")[1]
eq(#class_nodes(badge_toggle,"cp-pin-count"),1)
eq(class_nodes(badge_toggle,"cp-pin-count")[1].props.text,"2")
eq(badge_toggle.props.title,"Pinned agents · 2")
pin_data.pins_open=true
local pin_tree=view.render(stub,pin_data,901,nil)
local open_toggle=class_nodes(pin_tree,"cp-pins-toggle")[1]
assert(has_class(open_toggle,"cp-pins-open"),"the open board marks its toggle")
-- Anchored under the heading, before the summary: it overlays the list, never sits at its end.
eq(#class_nodes(class_nodes(pin_tree,"cp-agents")[1],"cp-pin-board"),0)
local agents_section=class_nodes(pin_tree,"cp-agents-section")[1]
eq(has_class(agents_section.children[1],"cp-heading"),true)
eq(has_class(agents_section.children[2],"cp-pin-board"),true)
eq(has_class(agents_section.children[3],"cp-summary"),true)
eq(has_class(agents_section.children[4],"cp-agents"),true)
local board=class_nodes(pin_tree,"cp-pin-board")[1]
eq(board.props.key,"pin-board")
assert(has_class(board,"cp-pin-board-open"),"a click opens the board persistently")
eq(class_nodes(board,"cp-pin-board-head")[1].props.key,"pin-board-head")
eq(class_nodes(board,"cp-pin-board-title")[1].props.text,"Pinned agents")
eq(class_nodes(board,"cp-pin-board-count")[1].props.text,"2")
-- A flex-wrap board that fills the available sidebar width.
local grid=class_nodes(board,"cp-pin-board-grid")[1]
eq(grid.props.key,"pin-board-grid")
eq(#grid.children,2)
local cards=class_nodes(grid,"cp-pin-card")
eq(#cards,2)
eq(#class_nodes(grid,"cp-pin-card-item"),2)
eq(cards[1].props.actions.click,"pane:901")
eq(cards[1].props.key,"pin-card:s1")
assert(has_class(cards[1],"cp-pin-card-focused"),"the focused live agent gets a ring")
eq(class_nodes(cards[1],"cp-pin-card-name")[1].props.text,"Parent")
eq(class_nodes(cards[1],"cp-pin-card-state")[1].props.text,"Running")
eq(#class_nodes(cards[1],"cp-color-2"),1)
eq(cards[2].props.actions.click,"resume-session:s2")
eq(cards[2].props.key,"pin-card:s2")
assert(has_class(cards[2],"cp-pin-card-closed"),"closed pins read as closed")
eq(class_nodes(cards[2],"cp-pin-card-state")[1].props.text,"Closed")
eq(#class_nodes(cards[2],"cp-pin-card-folder"),0)
eq(#class_nodes(cards[2],"cp-pin-card-model"),0)
assert(string.find(cards[2].props.title,"oldwork",1,true),"the folder stays in the tooltip")
assert(string.find(cards[1].props.title,"Click to focus",1,true))
assert(string.find(cards[2].props.title,"Click to reopen",1,true))
eq(cards[1].props.aria,cards[1].props.title)
local unpin_roles={}
collect(pin_tree,function(node) return node.props~=nil and node.props.role=="switchboard.agent-unpin" end,unpin_roles)
eq(#unpin_roles,2)
eq(unpin_roles[1].props.actions.click,"unpin-pin:s:s1")
eq(unpin_roles[2].props.actions.click,"unpin-pin:s:s2")
eq(unpin_roles[1].props.key,"unpin:s1")
eq(unpin_roles[2].props.key,"unpin:s2")
-- Live cards keep the pin toggle beside their close x.
local card_pin=nil
collect(pin_tree,function(node) if node.props~=nil and node.props.role=="switchboard.agent-pin" then card_pin=node end end)
assert(card_pin,"missing the card's pin toggle")
eq(card_pin.props.actions.click,"pin-agent:901")
eq(card_pin.props.on,true)
eq(card_pin.props.title,"Unpin Parent")
local unpinned_pin=nil
collect(unpinned_tree,function(node) if node.props~=nil and node.props.role=="switchboard.agent-pin" then unpinned_pin=node end end)
eq(unpinned_pin.props.on,false)
eq(unpinned_pin.props.title,"Pin Parent")
-- Opened with nothing pinned: a message, no grid.
local empty_board_data=table.clone(finished_data)
empty_board_data.pins_open=true
local empty_board_tree=view.render(stub,empty_board_data,901,nil)
eq(#class_nodes(empty_board_tree,"cp-pin-board"),1)
assert(has_class(class_nodes(empty_board_tree,"cp-pin-board")[1],"cp-pin-board-open"),"an empty open board is still open")
eq(#class_nodes(empty_board_tree,"cp-pin-board-grid"),0)
eq(class_nodes(empty_board_tree,"cp-pin-board-empty")[1].props.text,"No pinned agents\nPin an agent from its card.")
eq(class_nodes(empty_board_tree,"cp-pin-board-count")[1].props.text,"0")
print("the header pin toggle opens a two-column pinned board")
-- The board's open state and contents are in the shell fingerprint.
local pin_cache=require("./render_cache").new(64)
local board_data=table.clone(finished_data)
board_data.pinned=pin_data.pinned
pin_cache.begin()
local closed_first=view.render(stub,board_data,901,pin_cache)
pin_cache.begin()
local closed_second=view.render(stub,board_data,901,pin_cache)
eq(#pin_cache.changed(),0)
assert(closed_second==closed_first,"a closed board rebuilds nothing")
board_data.pins_open=true
pin_cache.begin()
local pin_first=view.render(stub,board_data,901,pin_cache)
assert(pin_first~=closed_second,"opening the board rebuilds")
eq(#class_nodes(pin_first,"cp-pin-card-item"),2)
pin_cache.begin()
local pin_second=view.render(stub,board_data,901,pin_cache)
eq(#pin_cache.changed(),0)
assert(pin_second==pin_first,"unchanged open board reuses the tree")
board_data.pinned={board_data.pinned[1]}
pin_cache.begin()
local pin_after=view.render(stub,board_data,901,pin_cache)
assert(pin_after~=pin_first,"removing a pin rebuilds the board")
eq(#class_nodes(pin_after,"cp-pin-card-item"),1)
eq(class_nodes(pin_after,"cp-pin-board-count")[1].props.text,"1")
print("board state and pins travel through the shell fingerprint")
-- Several agents first seen in one update share `at`: pin slot keys must still differ, or Tern rejects the view.
local same_at_data=table.clone(finished_data)
same_at_data.project_colors={api=2}
same_at_data.pins_open=true
same_at_data.agents={
	{pane=901,name="Parent",state="working",project="api",progress={steps={}},subagents={},pinned=true},
	{pane=903,name="Second",state="idle",project="api",progress={steps={}},subagents={},pinned=true},
}
same_at_data.pinned={
	{at=21,pane=901,cwd="/api",name="Parent",project="api",live=true},
	{at=21,pane=903,cwd="/web",name="Second",project="api",live=true},
}
local same_at_tree=view.render(stub,same_at_data,901,nil)
local same_at_keyed={}
collect(same_at_tree,function(node) return node.props~=nil and node.props.key~=nil end,same_at_keyed)
local same_at_seen={}
for _,node in same_at_keyed do
	local key=node.props.key
	-- The shell root and its grid trigger share the `keep-focus` action key by design; pins are the subject here.
	if key == "keep-focus" then continue end
	assert(same_at_seen[key]==nil,"duplicate key " .. tostring(key))
	same_at_seen[key]=true
end
local same_at_cards=class_nodes(same_at_tree,"cp-pin-card")
eq(#same_at_cards,2)
eq(same_at_cards[1].props.actions.click,"pane:901")
eq(same_at_cards[2].props.actions.click,"pane:903")
eq(same_at_cards[1].props.key,"pin-card:21:901:/api")
eq(same_at_cards[2].props.key,"pin-card:21:903:/web")
local same_at_unpins={}
collect(same_at_tree,function(node) return node.props~=nil and node.props.role=="switchboard.agent-unpin" end,same_at_unpins)
eq(#same_at_unpins,2)
eq(same_at_unpins[1].props.actions.click,"unpin-pin:a:21:901")
eq(same_at_unpins[2].props.actions.click,"unpin-pin:a:21:903")
print("same-at pins keep unique keys and separate actions")
-- A session listed twice in history must render once: Tern fails the whole view on duplicate child keys.
local dup_data=table.clone(slot_data)
dup_data.closed={{session="s9",name="Old",project="api"},{session="s9",name="Old again",project="api"}}
local dup_tree=view.render(stub,dup_data,901,nil)
eq(#class_nodes(dup_tree,"cp-closed"),1)
print("duplicate closed sessions render once")
return true
