local section_sizes = require("./section_sizes")

local SECTION_SIZES_KEY = "section_sizes"
local UPDATE_ACTION = "switchboard.sidebar.update"
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

local OPEN = "cp-subagent-open"

-- Flips the keyed disclosure button's open class and aria-expanded in a pushed tree.
local function toggle_disclosure(node, key): boolean
	if type(node) ~= "table" then return false end
	local p = node.p
	if type(p) == "table" and p.key == key then
		local class = p.class or ""
		local from, to = string.find(class, OPEN, 1, true)
		local open = from ~= nil
		-- Plain splice: OPEN contains hyphens, which are quantifiers in Lua patterns.
		p.class = if open then string.gsub(string.sub(class, 1, from - 1), "%s+$", "") .. string.sub(class, to + 1) else class .. " " .. OPEN
		if type(p.attrs) == "table" then p.attrs["aria-expanded"] = if open then "false" else "true" end
		return true
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			if toggle_disclosure(child, key) then return true end
		end
	end
	return false
end

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
			if parent and type(state.tree) == "table" and toggle_disclosure(state.tree, "subagents-toggle" .. parent) then
				local open = tern.kv.get(EXPANDED_KEY)
				if type(open) ~= "table" then open = {} end
				open[parent] = not open[parent]
				tern.kv.set(EXPANDED_KEY, open)
				return
			end
			send_to_window(cx, "action", {pane=cx.pane,event=ev})
		end
	end,
}

tern.block.define("sidebar", spec)

return true
