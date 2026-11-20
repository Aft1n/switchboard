local launchers=require("./launchers")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
eq(#launchers.native,13)
eq(launchers.native_by_id("new_task_manager_block").label,"Task manager")
eq(launchers.native_by_id("new_git_block").icon,"branch")
eq(launchers.native_by_id("new_git_block").group,"Work")
eq(launchers.native_by_id("new_notebook").group,"Data")
eq(launchers.native_by_id("new_browser_block").group,"Surfaces")
eq(launchers.native_by_id("nope"),nil)

-- Plugin blocks are the palette entries that open a block; native canvas and the sidebar itself are not.
local fake={session={block_types=function()
	return {
		{kind="tern.canvas",title="Canvas",icon="sparkle",palette=false},
		{kind="taskboard.board",title="Task board",icon="check",palette=true},
		{kind="switchboard.sidebar",title="Switchboard",icon="terminal",palette=false},
		{kind="cez.cockpit",title="cez",icon="terminal",palette=true},
	}
end}}
local blocks=launchers.plugin_blocks(fake,1000)
eq(#blocks,2)
eq(blocks[1].kind,"taskboard.board")
eq(blocks[2].kind,"cez.cockpit")
eq(launchers.plugin_blocks(fake,2000)[1].kind,"taskboard.board")
eq(launchers.native_by_id("new_git_block").glimpse,true)
eq(launchers.native_by_id("new_browser_block").prompt,true)
eq(launchers.native_by_id("new_task_manager_block").prompt,nil)

-- The centered overlay engine: open a native block, float it unfocused, style the focused float, then focus it.
local clock, timers, calls, sheets = 0, {}, {}, {}
launchers.runtime = {
	now = function() return clock end,
	css = function(name, source) sheets[name] = source end,
	timer = function(_, fn) table.insert(timers, fn) end,
}
local panes = {}
local function set_panes(list) panes = list end
local function fake_cx()
	local cx = {}
	cx.session = {
		tab_of = function() return 1 end,
		panes = function() return panes end,
		pane = function(_, id) for _, p in panes do if p.pane == id then return p end end return nil end,
	}
	cx.layout = {
		float = function(_, ...) table.insert(calls, {"float", ...}); return true end,
		dock = function(_, id) table.insert(calls, {"dock", id}); return true end,
		close = function(_, id) table.insert(calls, {"close", id}); return true end,
		focus = function(_, id) table.insert(calls, {"focus", id}) end,
	}
	return cx
end
local function run_timers(cx) local due = timers; timers = {}; for _, fn in due do fn(cx) end end
local function start(entry)
	panes = {{pane=2,tab=1,floating=false}}
	calls = {}
	local cx = fake_cx()
	launchers.begin(cx, entry, 2, {}, function() table.insert(panes, {pane=9,tab=1,floating=true}); return true end)
	run_timers(cx)
	return cx
end
local task_manager = launchers.native_by_id("new_task_manager_block")
local cx = start(task_manager)
eq(calls[1][1], "float"); eq(calls[1][2], 9); eq(calls[1][3], 2); eq(calls[1][4], "tl")
eq(calls[1][5].focus, false)
eq(launchers.overlay_pane(), 9)
assert(string.find(sheets["switchboard-overlay"], "translate(-50%, -50%)", 1, true), "overlay is centered by style")
assert(string.find(sheets["switchboard-overlay"], ":not(.pip-expanded)", 1, true), "expanded fullscreen escapes the centered style")
assert(string.find(sheets["switchboard-overlay"], ".tn-hb", 1, true), "the float header buttons stay visible")
run_timers(cx)
eq(calls[#calls][1], "focus"); eq(calls[#calls][2], 9)
eq(launchers.is_overlay(cx, 9), true)

-- Click-away close of an inspector closes it; a block that holds state docks instead.
panes = {{pane=2,tab=1,floating=false}}
launchers.begin(cx, task_manager, 2, {}, function() table.insert(panes, {pane=9,tab=1,floating=true}); return true end)
run_timers(cx)
calls = {}
launchers.finish(cx)
eq(calls[1][1], "close"); eq(calls[1][2], 9)
eq(sheets["switchboard-overlay"], "")
local shell = launchers.native_by_id("new_shell_block")
panes = {{pane=2,tab=1,floating=false}}
launchers.begin(cx, shell, 2, {}, function() table.insert(panes, {pane=10,tab=1,floating=true}); return true end)
run_timers(cx)
calls = {}
launchers.finish(cx)
eq(calls[1][1], "dock"); eq(calls[1][2], 10)

-- The native "Return to split" button docks without telling the plugin; sync drops the style and state.
panes = {{pane=2,tab=1,floating=false}}
launchers.begin(cx, task_manager, 2, {}, function() table.insert(panes, {pane=11,tab=1,floating=true}); return true end)
run_timers(cx)
for _, p in panes do if p.pane == 11 then p.floating = false end end
launchers.sync(cx)
eq(sheets["switchboard-overlay"], "")
eq(launchers.overlay_pane(), nil)
eq(launchers.is_overlay(cx, 11), false)

-- A pane that appears after the short window (no prompt) is not adopted.
panes = {{pane=2,tab=1,floating=false}}; calls = {}
launchers.begin(cx, task_manager, 2, {}, function() return true end)
run_timers(cx)
clock = 20000
table.insert(panes, {pane=12,tab=1,floating=true})
launchers.created(cx, {})
eq(launchers.overlay_pane(), nil)
eq(#calls, 0)
print("launcher catalog and overlay checks passed")
return true
