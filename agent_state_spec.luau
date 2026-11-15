local state = require("./agent_state")

local function eq(actual, expected, message)
	assert(actual == expected, (message or "value") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

local function captured_docs_view(send_name)
	-- Captured DOCS shape: Message is inside a GenericContainer one level below
	-- its composer Group; Return is a sibling of that container. Running is in
	-- the section header and must not be mistaken for composer state.
	local composer = {
		role = "Group",
		children = {
			{ role = "Group", name = "No agents running" },
			{ role = "GenericContainer" },
			{ role = "Meter", name = "Context" },
			{
				role = "GenericContainer",
				children = { { role = "TextInput", name = "Message", value = "do not inspect" } },
			},
			{ role = "GenericContainer", name = "Title" },
			{ role = "Group", name = "Switch model" },
			{ role = "Group", name = "Status" },
			{ role = "Group", name = "Start dictation" },
			{ role = "Image", name = send_name },
			{ role = "GenericContainer", name = "handoffd" },
		},
	}
	return {
		role = "Region",
		name = "Agent block",
		children = {
			{ role = "SectionHeader", children = { { role = "GenericContainer" }, { role = "Image", name = "Running" } } },
			{
				role = "Group",
				children = {
					{
						role = "Group",
						children = { { role = "Group" }, { role = "GenericContainer", children = { composer } } },
					},
				},
			},
		},
	}
end

local function captured_observ_busy_view()
	return {
		role = "Region",
		name = "Agent block",
		children = {
			{ role = "SectionHeader", children = { { role = "Image", name = "Running" } } },
			{
				role = "Group",
				children = {
					{ role = "Group", name = "No agents running" },
					{ role = "Image", name = "Working" },
					{ role = "TextInput", name = "Message", value = "never inspect" },
					{ role = "GenericContainer", name = "Stop esc" },
				},
			},
		},
	}
end

-- The captured DOCS composer is send-ready, even though SDK/OSC state is stale.
local effective, source = state.reconcile("working", captured_docs_view("Return"), nil)
eq(effective, "idle", "composer Return overrides stale busy")
eq(source, "view", "source identifies native view")

-- A running icon elsewhere in the window is not evidence about the composer.
effective, source = state.reconcile("working", {
	role = "Region",
	children = {
		{ role = "SectionHeader", children = { { role = "Image", name = "Running" } } },
	},
}, nil)
eq(effective, "working", "header icon does not clear busy")
eq(source, "reported", "header-only state falls back")

-- The observed busy composer has a Stop esc container beside Message.
effective, source = state.reconcile("idle", captured_observ_busy_view(), nil)
eq(effective, "working", "composer Stop marks running")
eq(source, "view", "Stop source identifies native view")

-- TSP sendability alone is ambiguous: a queued prompt can be sendable while
-- the model is working, so it cannot override SDK state without more evidence.
local tsp = {
	main = {
		id = "editor",
		k = "col",
		p = { role = "omp.editor" },
		c = {
			{ id = "input", k = "editor", p = { sendable = true, text = "ignored" } },
			{ id = "send", k = "kbd", p = { role = "omp.composer.send" } },
		},
	},
}
effective, source = state.reconcile("working", nil, tsp)
eq(effective, "working", "unverified TSP state does not clear busy")

-- Waiting for user input and terminal exit are not composer-idle states.
effective, source = state.reconcile("waiting_input", captured_docs_view("Return"), tsp)
eq(effective, "waiting_input", "waiting input remains distinct")
eq(source, "reported", "attention state stays authoritative")
effective = state.reconcile("exited", captured_docs_view("Return"), tsp)
eq(effective, "exited", "exited remains authoritative")

-- Missing and truncated observations cannot turn a reported busy state idle.
effective = state.reconcile("working", nil, nil)
eq(effective, "working", "missing view and surface fall back")
local truncated_view = captured_docs_view("Return")
truncated_view.more = 1
effective = state.reconcile("working", truncated_view, nil)
eq(effective, "working", "truncated view cannot clear busy")
local truncated_stop = captured_observ_busy_view()
truncated_stop.more = 1
effective = state.reconcile("idle", truncated_stop, nil)
eq(effective, "working", "visible composer Stop remains positive evidence")
-- A newly observed Stop replaces a previous idle result; no idle cache exists.
effective = state.reconcile("idle", captured_docs_view("Return"), nil)
eq(effective, "idle", "first observation is idle")
effective = state.reconcile("idle", captured_observ_busy_view(), nil)
eq(effective, "working", "new turn Stop invalidates prior idle")

print("agent state checks passed")
return true
