local h = require("./harness")
local subagents = require("../subagents")

h.suite("subagents", function(s)
	s.test("task progress updates to its completed result by OMP id", function()
		local children = subagents.scan({
			{
				role = "assistant",
				text = "delegating work",
				tools = {
					{
						name = "TaSk",
						metadata = {
							progress = {
								{
									id = "ParserReview",
									status = "running",
									task = "Review the task metadata parser",
									description = "Review parser metadata",
									stage = "Inspecting transcript details",
									resolvedModelIdentity = "openai/gpt-5.2",
									pane = 42,
									cwd = "/tmp/worktree",
								},
							},
							results = {
								{
									id = "ParserReview",
									status = "completed",
									exitCode = 0,
									task = "Review the task metadata parser",
									description = "Review parser metadata",
									resolvedModelIdentity = "openai/gpt-5.2",
									output = "The parser reads direct task metadata.",
								},
							},
						},
					},
				},
			},
		})

		s.eq(children, {
			{
				id = "ParserReview",
				title = "Review parser metadata",
				state = "done",
				model = "openai/gpt-5.2",
				step = "Inspecting transcript details",
				detail = "The parser reads direct task metadata.",
			},
		})
	end)

	s.test("only task metadata contributes children", function()
		local children = subagents.scan({
			{
				role = "assistant",
				text = "task metadata: this prose is not a child",
				tools = {
					{ name = "bash", metadata = { progress = { { id = "BashChild", status = "running", task = "ignore" } } } },
					{ name = "other", metadata = { results = { { id = "OtherChild", exitCode = 0, task = "ignore" } } } },
				},
			},
		})
		s.eq(children, {})
	end)

	s.test("assignment is a title fallback and pane is never guessed", function()
		local children = subagents.scan({
			{
				tools = {
					{
						name = "task",
						metadata = {
							progress = {
								{
									id = "queued-worker",
									status = "pending",
									task = "Long raw task prompt",
									assignment = "Inspect TSP metadata",
									modelOverride = "anthropic/claude-sonnet-4-5",
									stage = "Waiting to start",
									pane = 17,
									cwd = "/tmp/worktree",
								},
							},
						},
					},
				},
			},
		})

		s.eq(children, {
			{
				id = "queued-worker",
				title = "Inspect TSP metadata",
				state = "queued",
				model = "anthropic/claude-sonnet-4-5",
				step = "Waiting to start",
			},
		})
	end)

	s.test("bad IDs are ignored", function()
		local children = subagents.scan({
			{
				tools = {
					{
						name = "task",
						metadata = {
							progress = {
								{ id = "", status = "running", task = "empty id" },
								{ id = 12, status = "running", task = "numeric id" },
								{ id = "bad id", status = "running", task = "space in id" },
								{ id = "GoodId", status = "running", task = "valid id" },
							},
						},
					},
				},
			},
		})
		s.eq(children, { { id = "GoodId", title = "valid id", state = "working" } })
	end)

	s.test("empty transcript retains that parent's prior children", function()
		local prior = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = { { id = "ChildA", status = "running", task = "Parent A work" } } } } } },
		}, nil)
		local other_parent = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = { { id = "ChildB", status = "running", task = "Parent B work" } } } } } },
		}, nil)

		local retained_a = subagents.scan({}, prior)
		local retained_b = subagents.scan({}, other_parent)
		s.eq(retained_a, { { id = "ChildA", title = "Parent A work", state = "working" } })
		s.eq(retained_b, { { id = "ChildB", title = "Parent B work", state = "working" } })
	end)

	s.test("keeps the newest 32 child identities", function()
		local progress = {}
		local expected = {}
		for i = 1, 40 do
			local id = "child-" .. tostring(i)
			table.insert(progress, { id = id, status = "pending", task = "Task " .. tostring(i) })
			if i > 8 then table.insert(expected, id) end
		end
		local children = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = progress } } } },
		}, nil)
		local ids = {}
		for _, child in children do table.insert(ids, child.id) end
		s.eq(ids, expected)
	end)

	s.test("a different parent scan does not reuse module-global children", function()
		local parent_a = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = { { id = "SharedId", status = "running", task = "Parent A task" } } } } } },
		}, nil)
		local parent_b = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = { { id = "SharedId", status = "running", task = "Parent B task" } } } } } },
		}, nil)
		s.eq(parent_a[1].title, "Parent A task")
		s.eq(parent_b[1].title, "Parent B task")
	end)

	s.test("new rows record the clock passed to scan", function()
		local children = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "running", task = "Alpha work" },
				{ id = "Beta", status = "pending", task = "Beta work" },
			} } } } },
		}, nil, 1000)
		s.eq(children, {
			{ id = "Alpha", title = "Alpha work", state = "working", updated_at = 1000 },
			{ id = "Beta", title = "Beta work", state = "queued", updated_at = 1000 },
		})
	end)

	s.test("only a metadata change advances updated_at", function()
		local function message(stage)
			return { tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "running", task = "Alpha work", stage = "Reading" },
				{ id = "Beta", status = "running", task = "Beta work", stage = stage },
			} } } } }
		end
		local first = subagents.scan({ message("Waiting") }, nil, 1000)
		s.eq(first, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Waiting", updated_at = 1000 },
		})
		-- Same stage re-scan must not bump the clock.
		s.eq(subagents.scan({ message("Waiting") }, first, 20000), first)
		s.eq(subagents.scan({ message("Editing") }, first, 20000), {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Editing", updated_at = 20000 },
		})
	end)

	s.test("a changed row reorders only once its 30s bucket passes", function()
		local function messages(stage)
			return {
				{ tools = { { name = "task", metadata = { progress = {
					{ id = "Alpha", status = "running", task = "Alpha work", stage = "Reading" },
					{ id = "Beta", status = "running", task = "Beta work", stage = stage },
				} } } } },
			}
		end
		local first = subagents.scan(messages("Waiting"), nil, 1000)
		s.eq(first, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Waiting", updated_at = 1000 },
		})
		-- 20000 and 1000 share bucket 0, so the changed row keeps its slot.
		local same_bucket = subagents.scan(messages("Editing"), first, 20000)
		s.eq(same_bucket, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Editing", updated_at = 20000 },
		})
		-- 31000 lands in bucket 1 and overtakes bucket 0.
		s.eq(subagents.scan(messages("Testing"), same_bucket, 31000), {
			{ id = "Beta", title = "Beta work", state = "working", step = "Testing", updated_at = 31000 },
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
		})
	end)

	s.test("bucket, not raw timestamp, orders rows", function()
		local function messages(alphaStage, betaStage)
			return { tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "running", task = "Alpha work", stage = alphaStage },
				{ id = "Beta", status = "running", task = "Beta work", stage = betaStage },
				{ id = "Gamma", status = "running", task = "Gamma work", stage = "Waiting" },
			} } } } }
		end
		local first = subagents.scan({ messages("Reading", "Waiting") }, nil, 29000)
		s.eq(first, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 29000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Waiting", updated_at = 29000 },
			{ id = "Gamma", title = "Gamma work", state = "working", step = "Waiting", updated_at = 29000 },
		})
		-- Beta is newest but 29999 is still bucket 0: stable tie, no reorder.
		local ties = subagents.scan({ messages("Reading", "Editing") }, first, 29999)
		s.eq(ties, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 29000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Editing", updated_at = 29999 },
			{ id = "Gamma", title = "Gamma work", state = "working", step = "Waiting", updated_at = 29000 },
		})
		-- 30000 crosses into bucket 1; 29000 and 29999 stay behind it.
		s.eq(subagents.scan({ messages("Inspecting", "Editing") }, ties, 30000), {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Inspecting", updated_at = 30000 },
			{ id = "Beta", title = "Beta work", state = "working", step = "Editing", updated_at = 29999 },
			{ id = "Gamma", title = "Gamma work", state = "working", step = "Waiting", updated_at = 29000 },
		})
	end)

	s.test("a pending spawn row cannot demote a live child", function()
		local live = subagents.scan({
			{ tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "running", task = "Alpha work", stage = "Reading" },
			} } } } },
		}, nil, 1000)
		s.eq(live, {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000 },
		})
		-- OMP's spawn snapshot keeps its pending rows; it must not overwrite the
		-- working row a live scan already reported.
		s.eq(subagents.scan({
			{ tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "pending", task = "Alpha work", description = "Stale snapshot title", stage = "Waiting to start" },
			} } } } },
		}, live, 20000), live)
	end)

	s.test("a pending progress row cannot demote a completed child", function()
		local finished = subagents.scan({
			{ tools = { { name = "task", metadata = {
				progress = { { id = "Beta", status = "running", task = "Beta work" } },
				results = { { id = "Beta", status = "completed", exitCode = 0, task = "Beta work", output = "Done." } },
			} } } },
		}, nil, 1000)
		s.eq(finished[1].state, "done")
		-- The pending progress row's state, title and stage must all be ignored.
		s.eq(subagents.scan({
			{ tools = { { name = "task", metadata = { progress = {
				{ id = "Beta", status = "pending", task = "Beta work", description = "Stale snapshot title", stage = "Waiting to start" },
			} } } } },
		}, finished, 20000), finished)
	end)

	s.test("clean drops queued rows and ages out terminal rows 30 minutes after their wall stamp", function()
		local wall_now = 2_000_000
		local rows = {
			{ id = "queued-fresh", state = "queued", wall_at = wall_now - 1 },
			{ id = "queued-nil", state = "queued" },
			{ id = "working-old", state = "working", wall_at = wall_now - 5_000_000 },
			{ id = "waiting-old", state = "waiting_input", wall_at = wall_now - 5_000_000 },
			{ id = "done-fresh", state = "done", wall_at = wall_now - 1 },
			{ id = "failed-edge", state = "failed", wall_at = wall_now - 1_799_999 },
			{ id = "failed-boundary", state = "failed", wall_at = wall_now - 1_800_000 },
			{ id = "done-ancient", state = "done", wall_at = wall_now - 5_000_000 },
			{ id = "idle-nil", state = "idle" },
			{ id = "unknown-mid", state = "unknown", wall_at = wall_now - 1_000_000 },
			{ id = "stale-updated", state = "done", updated_at = 0, wall_at = wall_now - 1 },
			{ id = "fresh-updated", state = "done", updated_at = wall_now, wall_at = wall_now - 1_800_000 },
		}
		s.eq(subagents.clean(rows, wall_now), {
			{ id = "working-old", state = "working", wall_at = wall_now - 5_000_000 },
			{ id = "waiting-old", state = "waiting_input", wall_at = wall_now - 5_000_000 },
			{ id = "done-fresh", state = "done", wall_at = wall_now - 1 },
			{ id = "failed-edge", state = "failed", wall_at = wall_now - 1_799_999 },
			{ id = "idle-nil", state = "idle" },
			{ id = "unknown-mid", state = "unknown", wall_at = wall_now - 1_000_000 },
			{ id = "stale-updated", state = "done", updated_at = 0, wall_at = wall_now - 1 },
		})
	end)

	s.test("clean with no clock returns every row in order, queued and expired included", function()
		local rows = {
			{ id = "queued-any", state = "queued", wall_at = 0 },
			{ id = "done-ancient", state = "done", wall_at = 0 },
			{ id = "idle-nil", state = "idle" },
		}
		s.eq(subagents.clean(rows, nil), {
			{ id = "queued-any", state = "queued", wall_at = 0 },
			{ id = "done-ancient", state = "done", wall_at = 0 },
			{ id = "idle-nil", state = "idle" },
		})
	end)

	s.test("wall stamps persist across unchanged rescans and bump when a stage changes", function()
		local function message(stage)
			return { tools = { { name = "task", metadata = { progress = {
				{ id = "Alpha", status = "running", task = "Alpha work", stage = stage },
			} } } } }
		end
		local first = subagents.scan({ message("Reading") }, nil, 1000, 1_000_000)
		local expected_first = { { id = "Alpha", title = "Alpha work", state = "working", step = "Reading", updated_at = 1000, wall_at = 1_000_000 } }
		s.eq(first, expected_first)
		s.eq(subagents.scan({ message("Reading") }, first, 20000, 2_000_000), expected_first)
		s.eq(subagents.scan({ message("Editing") }, first, 20000, 2_000_000), {
			{ id = "Alpha", title = "Alpha work", state = "working", step = "Editing", updated_at = 20000, wall_at = 2_000_000 },
		})
	end)

	s.test("wait job results finish queued task rows, and background jobs never become rows", function()
		local children = subagents.scan({
			{ tools = {
				{ name = "task", metadata = { progress = { { id = "Alpha", status = "pending", task = "Alpha work" } } } } },
				{ name = "wait", metadata = { jobs = {
					{ id = "Alpha", status = "completed" },
					{ id = "bg_6", status = "failed" },
					{ id = "Ghost", status = "completed" },
				} } },
			} },
		})
		s.eq(children, {
			{ id = "Alpha", title = "Alpha work", state = "done" },
			{ id = "Ghost", title = "Ghost", state = "done" },
		})
	end)
end)

h.suite("native subagent rows", function(s)
 s.test("indexes current task roots after thousands of unrelated rows",function()
  local children={{id="old-task",k="tool",p={role="omp.tool.task"}}}
  for i=1,2500 do table.insert(children,{id="row"..i,k="text"}) end
  table.insert(children,{id="current-task",k="tool",p={role="omp.tool.task"}})
  s.eq(subagents.task_roots({main={k="col",c=children}}),{"current-task","old-task"})
 end)
 s.test("finds children after the task call leaves recent transcript messages",function()
  local rows=subagents.collect({{role="assistant",text="later work",tools={}}},
   {main={k="agent",id="old.Worker",p={name="Worker",status="failed"}}},{})
  s.eq(rows[1].id,"Worker")
  s.eq(rows[1].state,"failed")
  s.eq(subagents.collect({},nil,rows),rows)
 end)
 s.test("reads explicit native agent rows without transcript metadata", function()
  local live=subagents.from_surface({main={k="col",c={{k="agent",id="task.alpha",p={
   name="Alpha",task="Full assignment",model="luna",status="running"
  },c={{k="tool",p={intent="Checking files"}}}}}}},nil)
  s.eq(#live,1);s.eq(live[1].id,"Alpha");s.eq(live[1].title,"Alpha")
  s.eq(live[1].state,"working");s.eq(live[1].step,"Checking files")
  s.eq(live[1].detail,"Full assignment");s.eq(live[1].pane,nil)
  local done=subagents.from_surface({main={k="agent",p={name="Alpha",status="done"}}},live)
  s.eq(#done,1);s.eq(done[1].state,"done");s.eq(done[1].step,"Checking files")
 end)
end)
h.suite("subagent failures",function(s)
 s.test("restarted workers clear errors from a previous attempt",function()
  local old={{id="Worker",title="Worker",state="failed",error="403 old failure"}}
  local rows=subagents.scan({{tools={{name="task",metadata={progress={{id="Worker",status="running",lastIntent="Editing code"}}}}}}},old)
  s.eq(rows[1].state,"working");s.eq(rows[1].error,nil);s.eq(rows[1].step,"Editing code")
 end)

 s.test("keeps the provider error from the native failed row",function()
  local rows=subagents.from_surface({main={k="agent",p={name="Review",status="failed"},c={
   {k="text",p={role="omp.tool.error",spans={{t="403 "},{t="ENTITLEMENT_ERROR"}}}}
  }}})
  s.eq(rows[1].state,"failed")
  s.eq(rows[1].error,"403 ENTITLEMENT_ERROR")
 end)
end)
h.suite("native subagent navigation",function(s)

 s.test("parent navigation uses the native back-to-main action",function()
  local surface={surface={id="live"},main={id="dock",k="col",c={
   {id="3",k="col",p={role="omp.editor"},c={
    {id="3.focus/exit",k="row",p={role="omp.composer.exit",actions={click="focus:main-registry-id"}}},
   }},
  }}}
  s.eq(subagents.parent_event(surface),{ev="action",sf="live",id="3.focus/exit",act="focus:main-registry-id"})
  s.eq(subagents.parent_event({main={id="3",p={role="omp.editor"}}}),nil)
 end)
 s.test("nested display names resolve to their exact native registry key",function()
  local rows=subagents.from_surface({main={id="8h.Parent.Child",k="agent",p={name="Parent>Child",status="running"}}})
  s.eq(rows[1].id,"Parent.Child")
  s.eq(rows[1].title,"Parent>Child")
 end)
 s.test("targets the live editor and surface, not a guessed row or pane",function()
  local event=subagents.focus_event({surface={id="live-surface"},main={id="dock",k="col",c={
   {id="hud",k="row",p={role="omp.hud"}},
   {id="3",k="col",p={role="omp.editor"}},
  }}},"WebCoreFeatures")
  s.eq(event,{ev="action",sf="live-surface",id="3",act="focus:WebCoreFeatures"})
 end)
 s.test("does not fake navigation without a native editor",function()
  s.eq(subagents.focus_event({main={id="main",k="col"}},"Review"),nil)
  s.eq(subagents.focus_event(nil,"Review"),nil)
 end)
end)
s.test("vibe sessions become subagents and the latest result wins", function()
 local rows=subagents.scan({
  {role="assistant",tools={{name="vibe_spawn",metadata={screens={
   {id="perf-runtime",cli="good",state="running",turnMessage="Audit navigation"},
   {id="perf-bundle",cli="good",state="running"},
  }}}}},
  {role="assistant",tools={{name="vibe_wait",metadata={screens={
   {id="perf-runtime",state="idle",model="anthropic/claude-haiku-5-5:high",lastIntent="Writing report"},
   {id="perf-bundle",state="running",killed=true},
  }}}}},
 },nil)
 local by={}
 for _,row in rows do by[row.id]=row end
 s.eq(#rows,2)
 s.eq(by["perf-runtime"].state,"idle")
 s.eq(by["perf-runtime"].title,"perf-runtime")
 s.eq(by["perf-runtime"].step,"Writing report")
 s.eq(by["perf-bundle"].state,"failed")
end)
return true
