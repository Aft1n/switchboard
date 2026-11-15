local M = {}

local MAX_NODES = 5000
local MAX_DEPTH = 64

local function truncated(node)
	return type(node) == "table" and type(node.more) == "number" and node.more > 0
end

local function has_truncation(root)
	local seen, count = {}, 0
	local function walk(node, depth)
		if type(node) ~= "table" then return true end
		count += 1
		if count > MAX_NODES or depth > MAX_DEPTH then return true end
		if seen[node] then return true end
		seen[node] = true
		if truncated(node) then return true end
		if node.children ~= nil and type(node.children) ~= "table" then return true end
		if node.c ~= nil and type(node.c) ~= "table" then return true end
		local children = node.children or node.c
		if type(children) == "table" then
			for _, child in children do
				if walk(child, depth + 1) then return true end
			end
		end
		return false
	end
	return walk(root, 0)
end

local function native_composer(view)
	if type(view) ~= "table" then return nil end
	local candidates, search_truncated = {}, has_truncation(view)
	local seen, count = {}, 0
	local function message_in(container)
		if type(container) ~= "table" then return false end
		local seen_message, inspected = {}, 0
		local function find(node, depth)
			if type(node) ~= "table" then search_truncated = true; return false end
			inspected += 1
			if inspected > MAX_NODES or depth > MAX_DEPTH then search_truncated = true; return false end
			if seen_message[node] then return false end
			seen_message[node] = true
			if node.role == "TextInput" and node.name == "Message" then return true end
			if node.children ~= nil and type(node.children) ~= "table" then search_truncated = true; return false end
			for _, child in node.children or {} do
				if find(child, depth + 1) then return true end
			end
			return false
		end
		return find(container, 0)
	end
	local function walk(node, depth)
		if type(node) ~= "table" then return end
		count += 1
		if count > MAX_NODES or depth > MAX_DEPTH then search_truncated = true; return end
		if seen[node] then return end
		seen[node] = true
		local children = node.children
		if type(children) ~= "table" then return end
		local message, returned, stopped = false, false, false
		for _, child in children do
			if type(child) == "table" then
				if child.role == "TextInput" and child.name == "Message" then message = true end
				if child.role == "GenericContainer" and message_in(child) then message = true end
				if (child.role == "Image" or child.role == "Button") and child.name == "Return" then returned = true end
				if child.role == "GenericContainer" and child.name == "Stop esc" then stopped = true end
			end
		end
		if message and (returned or stopped) then
			table.insert(candidates, {
				state = if stopped then "working" elseif not search_truncated then "idle" else nil,
			})
		end
		for _, child in children do walk(child, depth + 1) end
	end
	walk(view, 0)
	if #candidates == 0 then return nil end
	for _, candidate in candidates do
		if candidate.state == "working" then return "working" end
	end
	if #candidates == 1 and not search_truncated then return candidates[1].state end
	return nil
end

function M.reconcile(reported, view, _surface)
	if reported == "waiting_input" or reported == "exited" then
		return reported, "reported"
	end
	local from_view = native_composer(view)
	if from_view == "working" then return "working", "view" end
	if from_view == "idle" then return "idle", "view" end
	return reported, "reported"
end

return M
