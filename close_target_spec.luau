local close_target=require("./close_target")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end

local closed_tab=7
local remote=4521191813414916
local agents={
	{pane=70,state="working"}, -- closed tab
	{pane=999,state="working"}, -- gone
	{pane=80,state="working"}, -- owned
	{pane=90,state="working"}, -- unavailable host
	{pane=remote,state="working"}, -- connected remote host
	{pane=100,state="working"},
}
local panes={
	{pane=70,tab=closed_tab},
	{pane=80,tab=8},
	{pane=90,tab=9},
	{pane=remote,tab=10},
	{pane=100,tab=11},
}
local hosts={
	{id=1,state="connected",panes={70,80,100},sessions={1}},
	{id=2,state="disconnected",panes={90},sessions={2}},
	{id=3,state="connected",panes={remote},sessions={3}},
}
eq(close_target.select(agents,panes,{}, {},closed_tab,{[80]=true},hosts,1),remote)
eq(agents[1].pane,70)
eq(agents[5].pane,remote)
print("remaining agent selection checks passed")

local default_sessions={
	{id=22,name="Default",tabs={2}}, -- other host appears first
	{id=11,name="Default",tabs={1}}, -- current host is preferred
}
local default_tabs={
	{id=2,session=22,pane=200},
	{id=1,session=11,pane=100},
}
local default_panes={
	{pane=200,tab=2},
	{pane=100,tab=1}, -- owned sidebar
	{pane=101,tab=1}, -- remaining content pane
}
local default_hosts={
	{id=2,state="connected",panes={200},sessions={22}},
	{id=1,state="connected",panes={100,101},sessions={11}},
}
eq(close_target.select({},default_panes,default_tabs,default_sessions,9,{[100]=true},default_hosts,1),101)
print("Default session fallback checks passed")

eq(close_target.select({},{{pane=301,tab=31}},{{id=31,session=31,pane=301}},{{id=31,name="Default"}},nil,{}, {},1),301)

eq(close_target.select({}, {}, {}, {{id=1,name="Work",tabs={1}}},nil,{}, {},1),nil)
eq(close_target.select({}, {}, {}, {},nil,{}, {},1),nil)
print("empty fallback checks passed")
return true
