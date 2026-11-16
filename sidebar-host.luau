local section_sizes = require("./section_sizes")

local SECTION_SIZES_KEY = "section_sizes"
local UPDATE_ACTION = "switchboard.sidebar.update"
local PATCH_ACTION = "switchboard.sidebar.patch"
local SELECT_ACTION = "switchboard.sidebar.select"
local EXPANDED_KEY = "subagents_expanded"

local function send_to_window(cx, route, value)
	local encoded = tern.base64.encode(tern.json.encode(value), { url = true })
	cx:open("switchboard://sidebar/" .. route .. "/" .. encoded)
end

local function apply_sizes(node, sizes)
	if type(node) ~= "table" then return end
	if node.k == "split" and type(node.p) == "table" and node.p.key == "sections" then
		node.p.sizes = sizes
		return
	end
	if type(node.c) == "table" then
		for _, child in node.c do apply_sizes(child, sizes) end
	end
end

local tree_flip = require("./tree_flip")

local spec = {
	init = function(_cx: BlockCx, args: { string }, _saved: any)
		local tree=nil
		if args[1] and args[1]~="" then local ok,value=pcall(tern.json.decode,args[1]); if ok and type(value)=="table" then tree=value end end
		return { tree = tree }
	end,

	title = function(): string
		return "Switchboard"
	end,

	view = function(state, _cx: BlockCx): BlockView
		local children = {}
		if type(state.tree) == "table" then
			-- Every tab owns a sidebar block with its own pushed tree; the shared sizes
			-- are applied on each render so a tab never shows a stale divider position.
			apply_sizes(state.tree, section_sizes.read(tern.kv.get(SECTION_SIZES_KEY)))
			table.insert(children, state.tree)
		end
		return { main = tern.ui.col(children) }
	end,

	event = function(state, ev: UiEvent, cx: BlockCx)
		if ev.ev == "action" and ev.act == SELECT_ACTION then
			-- The window's authoritative selection after a click: keep the block in step even
			-- when Tern focused a different pane than the one clicked.
			if type(ev.value) == "string" and type(state.tree) == "table" then
				pcall(tree_flip.select_card, state.tree, ev.value)
			end
			return
		end
		if ev.ev == "action" and ev.act == PATCH_ACTION then
			-- Only the cards that were rebuilt: replace the nodes with these keys in place.
			local ok, payload = pcall(tern.json.decode, ev.value)
			if not ok or type(payload) ~= "table" or type(payload.slots) ~= "table" or type(state.tree) ~= "table" then
				pcall(function() send_to_window(cx, "action", {pane=cx.pane,event={ev="action",act="switchboard.sidebar.resync"}}) end)
				return
			end
			local wanted, found = 0, 0
			for _ in payload.slots do wanted += 1 end
			local seen = {}
			local function patch(node)
				if type(node) ~= "table" then return end
				local p = node.p
				if type(p) == "table" and type(p.key) == "string" and payload.slots[p.key] ~= nil then
					seen[p.key] = true
					-- Replace the node's fields in place so the parent keeps its child slot.
					local fresh = payload.slots[p.key]
					for field in node do node[field] = nil end
					for field, value in fresh do node[field] = value end
					return
				end
				for _, child in node.c or {} do patch(child) end
			end
			patch(state.tree)
			for _ in seen do found += 1 end
			if found < wanted then
				pcall(function() send_to_window(cx, "action", {pane=cx.pane,event={ev="action",act="switchboard.sidebar.resync"}}) end)
			end
			return
		end
		if ev.ev == "action" and ev.act == UPDATE_ACTION then
			if type(ev.value) ~= "string" then
				return
			end
			local ok, tree = pcall(tern.json.decode, ev.value)
			if ok and type(tree) == "table" then
				state.tree = tree
			end
			return
		end

		-- Tern reports the split by its tree path ("main.keep-focus.1.sections"), not its key.
		if ev.ev == "change" and type(ev.id) == "string" and string.find(ev.id, "%.?sections$") then
			local sizes = section_sizes.normalize(ev.value)
			if not sizes or section_sizes.same(sizes, section_sizes.read(tern.kv.get(SECTION_SIZES_KEY))) then
				return
			end
			tern.kv.set(SECTION_SIZES_KEY, sizes)
			send_to_window(cx, "resize", {pane=cx.pane,sizes=sizes})
			return
		end

		if ev.ev == "action" then
			-- The disclosure is handled entirely here: flip the pushed tree and persist the shared kv
			-- flag the window reads on its next render. Calling into the window (cx:open) ran before
			-- this block could re-render and cost ~500 ms per click.
			local parent = type(ev.act) == "string" and string.match(ev.act, "^subagents:(%d+)$")
			if parent and type(state.tree) == "table" and tree_flip.toggle_disclosure(state.tree, "subagents-toggle" .. parent) then
				local open = tern.kv.get(EXPANDED_KEY)
				if type(open) ~= "table" then open = {} end
				open[parent] = not open[parent]
				tern.kv.set(EXPANDED_KEY, open)
				return
			end
			-- Instant selection: move the highlight in the block's own tree before the click
			-- travels to the window, which then only has to navigate.
			if type(state.tree) == "table" then
				local target = type(ev.act) == "string" and (string.match(ev.act, "^pane:(%d+)$") or string.match(ev.act, "^subagent:(%d+):"))
				if target then tree_flip.select_card(state.tree, target) end
			end
			send_to_window(cx, "action", {pane=cx.pane,event=ev})
		end
	end,
}

tern.block.define("sidebar", spec)

return true
