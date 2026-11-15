-- Persisted per-project color slot (kv `project_colors`). 36 slots keep a sidebar's
-- projects distinct; workspace rows and agent cards share one slot per project name.
local M = {}
M.TOTAL = 36
-- Real Tern tokens only. No red: red is reserved for urgent/needs-input states.
local TOKENS = {
	"--ansi2", "--ansi3", "--ansi4", "--ansi5", "--ansi6",
	"--ansi10", "--ansi11", "--ansi12", "--ansi13", "--ansi14",
	"--a1", "--a2", "--accent-ink", "--ok", "--warn", "--live", "--ink-pen",
}
-- Mixes start from cool/green tokens so no slot drifts toward red.
local COOL = {"--ansi4", "--ansi6", "--ansi2", "--a2", "--a1", "--accent-ink", "--ok"}

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

-- Seventeen direct tokens plus nineteen ordered cool-led mixes. The window applies
-- this once as a dynamic sheet; switchboard.css only carries the 1..6 fallback.
function M.css()
	local rules = {}
	for slot, token in ipairs(TOKENS) do
		table.insert(rules, string.format(".cp-color-%d { color: color-mix(in srgb, var(%s, var(--accent)) 40%%, var(--t2)) !important; }", slot, token))
	end
	for i = 1, 19 do
		local first = COOL[(i - 1) % #COOL + 1]
		local index = (i * 5) % #TOKENS
		local second = TOKENS[index + 1]
		if second == first then index = (index + 1) % #TOKENS; second = TOKENS[index + 1] end
		table.insert(rules, string.format(".cp-color-%d { color: color-mix(in srgb, color-mix(in srgb, var(%s, var(--accent)) 65%%, var(%s, var(--accent))) 40%%, var(--t2)) !important; }", #TOKENS + i, first, second))
	end
	return table.concat(rules, "\n")
end

return M
