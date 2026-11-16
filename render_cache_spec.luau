--!strict
local h = require("./spec/harness")
local render_cache = require("./render_cache")

h.suite("render_cache", function(s)
	s.test("same signature returns the same node", function()
		local cache = render_cache.new()
		local built = 0
		local a = cache.get("agent:1", "card|x", function()
			built += 1
			return {tag = "x"}
		end)
		local b = cache.get("agent:1", "card|x", function()
			built += 1
			return {tag = "y"}
		end)
		s.ok(a == b, "expected the cached node")
		s.eq(built, 1, "build should run once")
		s.eq(a.tag, "x")
	end)

	s.test("changed signature rebuilds the same slot", function()
		local cache = render_cache.new()
		local a = cache.get("agent:1", "card|x", function() return {tag = "x"} end)
		local b = cache.get("agent:1", "card|y", function() return {tag = "y"} end)
		s.ok(a ~= b, "expected a rebuild")
		s.eq(b.tag, "y")
		s.eq(cache.size(), 1, "a content change must not grow the cache")
	end)

	s.test("different identities keep different nodes", function()
		local cache = render_cache.new()
		local a = cache.get("agent:1", "card|x", function() return {tag = "a"} end)
		local b = cache.get("agent:2", "card|x", function() return {tag = "b"} end)
		s.ok(a ~= b, "different cards must not share a node")
		s.eq(cache.size(), 2)
	end)

	s.test("the limit clears the cache instead of growing", function()
		local cache = render_cache.new(2)
		local first = cache.get("a", "sig1", function() return {tag = "a"} end)
		cache.get("b", "sig1", function() return {tag = "b"} end)
		cache.get("c", "sig1", function() return {tag = "c"} end)
		s.eq(cache.size(), 1)
		local rebuilt = cache.get("a", "sig2", function() return {tag = "a2"} end)
		s.ok(rebuilt ~= first, "the cleared entry should be rebuilt")
		s.eq(rebuilt.tag, "a2")
	end)
end)

local view = require("./view")

local function stub_ui()
	local ui = {}
	ui.el = function(tag, props, children)
		return {tag = tag, props = props, p = props, children = children}
	end
	ui.node = function(kind, props, children)
		return {tag = kind, props = props, children = children}
	end
	ui.button = function(label, props)
		return {tag = "button", props = props, p = props}
	end
	return ui
end

local function find(node, key)
	if type(node) ~= "table" then return nil end
	if node.p and node.p.key == key then return node end
	for _, child in node.children or {} do
		local hit = find(child, key)
		if hit then return hit end
	end
	return nil
end

local function has_text(node, value)
	if type(node) ~= "table" then return false end
	if node.p and node.p.text == value then return true end
	for _, child in node.children or {} do
		if has_text(child, value) then return true end
	end
	return false
end

h.suite("view subtree cache", function(s)
	s.test("an unchanged card keeps its node; changed steps rebuild it", function()
		local ui = stub_ui()
		local cache = render_cache.new()
		local data = {
			projects = {}, running = 1, waiting = 0, quotas = {}, shortcuts = {},
			now = 1000,
			agents = {{
				pane = 7, name = "Agent", state = "working", project = "api",
				progress = {steps = {{label = "First step", status = "running"}}},
			}},
		}
		local first = find(view.render(ui, data, 7, cache), "agent7")
		s.ok(first ~= nil, "missing agent card")
		local again = find(view.render(ui, data, 7, cache), "agent7")
		s.ok(again == first, "unchanged card should reuse its node")

		data.agents[1].progress.steps[1].label = "Renamed step"
		local changed = find(view.render(ui, data, 7, cache), "agent7")
		s.ok(changed ~= first, "changed step label should rebuild the card")
		s.ok(has_text(changed, "Renamed step"), "the rebuilt card carries the new label")
	end)
end)

return true
