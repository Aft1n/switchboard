-- Persisted per-project color slot (kv `project_colors`). 36 slots keep a sidebar's
-- projects distinct; workspace rows and agent cards share one slot per project name.
local M = {}
M.TOTAL = 36
-- Theme tokens, one hue family each: orange, amber, green, cyan, blue, purple.
-- The previous mix collapsed because normal/bright variants and ok/warn/live aliases
-- repeated the same hue, then 60% --t2 drained the chroma. Each family now contributes
-- a pure hue and two mixes into its neighbour, and only two tones, so every slot keeps
-- a real theme hue. Red stays out: red means urgent or needs input.
local FAMILIES = {"--ink-pen", "--ansi3", "--ansi2", "--ansi6", "--ansi4", "--ansi5"}

local function valid(value)
	return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= M.TOTAL
end

local function occupied(colors, slot, except)
	for name, value in pairs(colors) do
		if name ~= except and value == slot then return true end
	end
	return false
end

-- Repair legacy duplicate/invalid slots. Names keep their first valid claim in
-- sorted order; the rest take the lowest free slots. True when a name moved.
function M.rebalance(store)
	if type(store) ~= "table" then return false end
	local colors = store.colors
	if type(colors) ~= "table" then store.colors = {}; return false end
	local names = {}
	for name in pairs(colors) do
		if type(name) == "string" and name ~= "" then table.insert(names, name) end
	end
	table.sort(names)
	local claimed, moved = {}, false
	for _, name in ipairs(names) do
		local slot = colors[name]
		if valid(slot) and not claimed[slot] then claimed[slot] = name end
	end
	local free = 1
	for _, name in ipairs(names) do
		local old = colors[name]
		if not (valid(old) and claimed[old] == name) then
			while claimed[free] do free = free + 1 end
			if free > M.TOTAL then
				colors[name] = nil
				moved = moved or old ~= nil
			else
				colors[name] = free
				claimed[free] = name
				moved = moved or old ~= free
				free = free + 1
			end
		end
	end
	local start = 1
	while start <= M.TOTAL and claimed[start] do start = start + 1 end
	store.next = if start > M.TOTAL then 1 else start
	return moved
end

function M.ensure(store, name)
	if type(store) ~= "table" or type(name) ~= "string" or name == "" then return nil end
	local colors = store.colors
	if type(colors) ~= "table" then colors = {}; store.colors = colors end
	local slot = colors[name]
	if valid(slot) and not occupied(colors, slot, name) then return slot end
	local start = store.next
	if not valid(start) then start = 1 end
	for offset = 0, M.TOTAL - 1 do
		local candidate = (start - 1 + offset) % M.TOTAL + 1
		if not occupied(colors, candidate) then
			colors[name] = candidate
			store.next = candidate % M.TOTAL + 1
			return candidate
		end
	end
	return nil
end

function M.class(color)
	if color == nil then return nil end
	return "cp-color-" .. tostring(color)
end

-- 18 token recipes (6 pure families plus a 68/32 and 32/68 mix into the next family),
-- each in two tones: 50% over --t2 (muted, AA contrast) and 60% over --ink. Slots walk
-- five recipes at a time, so consecutive projects never share a hue family.
local function base(index)
	local family = math.floor(index / 3) % #FAMILIES + 1
	local token = FAMILIES[family]
	if index % 3 == 0 then return string.format("var(%s, var(--accent))", token) end
	local next_token = FAMILIES[family % #FAMILIES + 1]
	local share = if index % 3 == 1 then 68 else 32
	return string.format("color-mix(in srgb, var(%s, var(--accent)) %d%%, var(%s, var(--accent)))", token, share, next_token)
end

function M.css()
	local rules = {}
	for slot = 1, M.TOTAL do
		local tone = math.floor((slot - 1) / 18)
		local recipe = (((slot - 1) % 18) * 5) % 18
		local tail = if tone == 0 then "50%, var(--t2)" else "60%, var(--ink)"
		table.insert(rules, string.format(".cp-color-%d { color: color-mix(in srgb, %s %s) !important; }", slot, base(recipe), tail))
	end
	return table.concat(rules, "\n")
end

return M
