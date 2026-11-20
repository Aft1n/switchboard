local history=require("./tree_history")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end

-- Live entries win; a project that vanished keeps its last tabs, and nothing is duplicated.
local saved={at=100,projects={
	{name="api",path="/w/api",tabs={{title="Fix",session="s1"},{title="Shell"}}},
	{name="web",path="/w/web",tabs={{title="Build",session="s2"}}},
}}
local live={
	{name="api",path="/w/api",tabs={}},
	{name="new",path="/w/new",tabs={{title="Chat",session="s3"}}},
}
local merged=history.merge(saved, live, 200)
eq(merged.at,200)
eq(#merged.projects,3)
eq(merged.projects[1].name,"api")
eq(merged.projects[1].tabs[1].title,"Fix") -- the live project had no tabs yet: keep the saved ones
eq(merged.projects[2].name,"new")
eq(merged.projects[3].name,"web") -- vanished, retained
eq(#merged.projects[3].tabs,1)

-- A live tab without a session keeps the saved session id for the same folder and title.
local relive={projects={{name="api",path="/w/api",tabs={{title="Fix",cwd="/w/api"}}}}}
local remembered=history.merge({at=1,projects={{name="api",path="/w/api",tabs={{title="Fix",cwd="/w/api",session="s1"}}}}},relive,2)
eq(remembered.projects[1].tabs[1].session,"s1")

-- Restore only what is missing: path must exist, not be live by path or name, and never Default.
local plan=history.plan(saved, live, function(path) return path ~= "/w/missing" end)
eq(plan.projects_count,1)
eq(plan.projects[1].name,"web")
eq(plan.tabs_count,1)
eq(plan.projects[1].tabs[1].session,"s2")

local default={at=1,projects={{name="Default",path="/Users/aftin",tabs={}}}}
eq(history.plan(default, {}, function() return true end).projects_count,0)
local missing={at=1,projects={{name="gone",path="/w/missing",tabs={}}}}
eq(history.plan(missing, {}, function() return false end).projects_count,0)

-- The banner asks constantly; folder checks are cached for a while.
local calls=0
local function exists() calls+=1; return true end
local cached=history.plan_cached(saved, live, exists, 1000)
eq(calls,2) -- the saved projects with paths
history.plan_cached(saved, live, exists, 1001)
eq(calls,2)
print("tree history checks passed")
return true
