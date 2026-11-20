-- What the footer launcher row and its hover card offer: built-in Tern blocks, plus the installed plugin
-- blocks. Built-in blocks are native palette actions (they never appear in `block_types`), so their ids,
-- labels and icons live here once.
local M = {}

M.native = {
	{action="new_task_manager_block",group="Work",label="Task manager",icon="list-checks"},
	{action="new_board_block",group="Work",label="Board",icon="list-checks"},
	{action="new_git_block",glimpse=true,group="Work",label="Git",icon="branch"},
	{action="new_browser_block",keep=true,prompt=true,group="Surfaces",label="Browser",icon="globe"},
	{action="new_screen_block",group="Surfaces",label="Screen",icon="globe"},
	{action="new_agent_block",keep=true,group="Work",label="Agent",icon="terminal"},
	{action="new_shell_block",keep=true,group="Work",label="Shell",icon="terminal"},
	{action="new_notebook",keep=true,group="Data",label="Notebook",icon="file"},
	{action="new_note",keep=true,group="Data",label="Note",icon="file"},
	{action="new_database",keep=true,prompt=true,group="Data",label="Database",icon="database"},
	{action="new_memory_database",keep=true,group="Data",label="Memory DB",icon="database"},
	{action="new_canvas_block",keep=true,group="Surfaces",label="Canvas",icon="sparkle"},
	{action="new_carly_block",keep=true,group="Surfaces",label="Carly",icon="sparkle"},
}

-- Centered overlay hack: Tern gives only git a real `how = "glimpse"`; task manager, board, screen and the
-- terminals open as tiled splits. A plugin style sheet restyles the one focused picture-in-picture card into a
-- centered window with a dimmed backdrop, and Tern's own float chrome stays on top: "Expand picture in
-- picture" (⇧⌘↵) fills the block area, "Return to split" makes it a tiled block, and "Close block" ends it.
local function rt() return M.runtime or tern end
local SHEET = "switchboard-overlay"
local OVERLAY_CSS = [[
.tn-stage .tn-pane.tn-float-card.pip.pip-focus:not(.pip-expanded) {
	position: fixed !important; left: 50% !important; top: 50% !important; right: auto !important; bottom: auto !important;
	width: min(1100px, 88vw) !important; height: min(720px, 80vh) !important;
	transform: translate(-50%, -50%) !important;
	box-shadow: 0 0 0 4000px rgba(0, 0, 0, 0.34), 0 24px 80px rgba(0, 0, 0, 0.4) !important;
	border-radius: 14px !important; z-index: 60 !important;
}
.tn-stage .tn-pane.tn-float-card.pip.pip-focus .tn-hb { opacity: 1 !important; pointer-events: auto !important; }
]]
M.OVERLAY_CSS = OVERLAY_CSS

local overlay = nil -- {entry, over, tab, owned, before, deadline, pane}

local function style(on) rt().css(SHEET, if on then OVERLAY_CSS else "") end

local function adopt(cx, pane)
	local o = overlay
	if not o or o.pane then return end
	o.pane = pane
	o.grace = rt().now() + 700
	pcall(cx.layout.float, cx.layout, pane, o.over, "tl", {focus = false, size = {0.9, 0.9}})
	style(true)
	-- The float lands unfocused; its centered card only exists once the pane has focus.
	rt().timer(0, function(nextCx)
		if nextCx and overlay == o then pcall(nextCx.layout.focus, nextCx.layout, pane) end
	end)
end

local function scan(cx, tries)
	local o = overlay
	if not o or o.pane then return end
	if rt().now() > o.deadline then overlay = nil; return end
	for _, pane in cx.session:panes() do
		if pane.tab == o.tab and not o.owned[pane.pane] and not o.before[pane.pane] then adopt(cx, pane.pane); return end
	end
	if tries > 0 then rt().timer(150, function(nextCx) if nextCx then scan(nextCx, tries - 1) end end) end
end

function M.overlay_pane() return overlay and overlay.pane end
function M.overlay_owner() return overlay and overlay.over end

-- True only while that pane is still the floating overlay (not after "Return to split" docked it).
function M.is_overlay(cx, pane)
	local o = overlay
	if not o or o.pane ~= pane then return false end
	local info = cx.session:pane(pane)
	return info ~= nil and info.floating == true
end

-- Ends the overlay without touching a block that was already expanded into the split.
function M.finish(cx)
	local o = overlay
	if not o then return end
	overlay = nil
	style(false)
	local info = o.pane and cx.session:pane(o.pane)
	if info and info.floating then
		if o.entry and o.entry.keep then pcall(cx.layout.dock, cx.layout, o.pane)
		else pcall(cx.layout.close, cx.layout, o.pane) end
	end
end

-- Runs `run` (which opens the native block) and floats it over `over`. A block that waits on a prompt
-- (browser URL, database chooser: `prompt = true`) is caught for a minute; the rest only for a moment.
function M.begin(cx, entry, over, owned, run)
	M.finish(cx)
	local tab = cx.session:tab_of(over)
	if not tab then run(); return end
	local before = {}
	for _, pane in cx.session:panes() do before[pane.pane] = true end
	overlay = {entry = entry, over = over, tab = tab, owned = owned, before = before,
		deadline = rt().now() + (if entry.prompt then 60000 else 3000)}
	if not run() then overlay = nil; return end
	rt().timer(0, function(nextCx) if nextCx then scan(nextCx, 3) end end)
end

function M.created(cx, owned)
	if overlay and not overlay.pane then overlay.owned = owned; scan(cx, 0) end
end

function M.closed(cx, pane)
	local o = overlay
	if o and o.pane == pane then overlay = nil; style(false) end
end

-- The native "Return to split" button docks the card without telling us: drop the style on the next tick.
function M.sync(cx)
	local o = overlay
	if o and o.pane and not M.is_overlay(cx, o.pane) then overlay = nil; style(false) end
end

-- `cx.sessions:create` returns the new session id (a number) on current Tern; accept an object too.
function M.session_id(value)
	if type(value) == "table" then return value.id end
	return value
end

function M.native_by_id(id)
	for _, entry in M.native do if entry.action == id then return entry end end
	return nil
end

-- Plugin blocks that a palette entry would open; read at most every 30 s because enabling a plugin is rare
-- and `block_types` is a native call on the window thread.
local blocks, blocks_at = {}, -math.huge
function M.plugin_blocks(cx, now)
	if now - blocks_at < 30000 then return blocks end
	blocks_at = now
	blocks = {}
	local ok, list = pcall(function() return cx.session:block_types() end)
	if not ok then return blocks end
	for _, block in list do
		-- `tern.canvas` is a native block opened by its own action; the sidebar itself is not a launcher.
		if block.palette and string.sub(block.kind, 1, 5) ~= "tern." and block.kind ~= "switchboard.sidebar" then
			blocks[#blocks + 1] = {kind=block.kind,label=block.title,icon=block.icon}
		end
	end
	return blocks
end

return M
