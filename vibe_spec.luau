local vibe = require("./vibe")
local subagents = require("./subagents")
local function eq(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end

local lines = {
	spawn = {type = "message", message = {role = "toolResult", toolName = "vibe_spawn", details = {screens = {
		{id = "perf-runtime", state = "running", turnMessage = "Audit"}}}}},
	wait = {type = "message", message = {role = "toolResult", toolName = "vibe_wait", details = {screens = {
		{id = "perf-runtime", state = "idle", model = "m", lastIntent = "Writing report"},
		{id = "device-deploy", state = "running", currentTool = "wait"}}}}},
	other = {type = "message", message = {role = "toolResult", toolName = "bash", details = {}}},
}
local function decode(line)
	local entry = lines[line]
	if not entry then error("bad json") end
	return entry
end

local messages = vibe.messages("spawn\nother\nnot json\nwait\n", decode)
eq(#messages, 2)
local rows = subagents.scan(messages, nil)
local by = {}
for _, row in rows do by[row.id] = row end
eq(#rows, 2)
eq(by["perf-runtime"].state, "idle")
eq(by["perf-runtime"].step, "Writing report")
eq(by["device-deploy"].state, "working")
eq(by["device-deploy"].step, "wait")

eq(vibe.used({{tools = {{name = "bash"}, {name = "vibe_wait"}}}}), true)
eq(vibe.used({{tools = {{name = "task"}}}}), false)
eq(#vibe.messages(nil, decode), 0)
eq(vibe.command("/s/a b.jsonl")[5], "/s/a b.jsonl")
local subagents = require("./subagents")
local rows = subagents.scan({{role = "assistant", tools = {{name = "vibe_wait", metadata = {screens = {{id = "perf-runtime", state = "working"}}}}}}}, nil, nil, nil)
eq(rows[1].id, "perf-runtime")
eq(subagents.scan({}, rows, 1000, nil)[1].id, "perf-runtime")
print("vibe session parsing checks passed")
return true
