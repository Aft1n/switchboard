--!strict
-- Tiny test harness: suites, tests, deep equality, a runner that exits 1 on failure.
-- Run every suite with `luau spec/run.luau`.

export type Suite = {
	test: (name: string, fn: () -> ()) -> (),
	eq: (actual: any, expected: any, msg: string?) -> (),
	ok: (value: any, msg: string?) -> (),
}

type Case = { name: string, fn: () -> () }
type Group = { name: string, cases: { Case } }

local M = {}

local groups: { Group } = {}

local function repr(v: any, seen: { [any]: boolean }?): string
	local t = type(v)
	if t == "string" then
		return string.format("%q", v)
	end
	if t ~= "table" then
		return tostring(v)
	end
	seen = seen or {}
	if seen[v] then
		return "<cycle>"
	end
	seen[v] = true
	local parts = {}
	local n = #v
	if n > 0 then
		for i = 1, math.min(n, 20) do
			table.insert(parts, repr(v[i], seen))
		end
	else
		local keys = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		for _, k in keys do
			table.insert(parts, k .. "=" .. repr(v[k], seen))
		end
	end
	seen[v] = nil
	local open, close = "{", "}"
	if n > 0 then
		return open .. table.concat(parts, ", ") .. close
	end
	if #parts == 0 then
		return "{}"
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

function M.repr(v: any): string
	return repr(v)
end

local function deep_eq(a: any, b: any, seen: { [any]: any }?): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[a] == b then
		return true
	end
	seen[a] = b
	for k, v in a do
		if not deep_eq(v, b[k], seen) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

M.deep_eq = deep_eq

function M.suite(name: string, body: (Suite) -> ()): ()
	local group: Group = { name = name, cases = {} }
	local s: Suite = {
		test = function(cname: string, fn: () -> ())
			table.insert(group.cases, { name = cname, fn = fn })
		end,
		eq = function(actual: any, expected: any, msg: string?)
			if not deep_eq(actual, expected) then
				error(
					(msg and (msg .. ": ") or "")
						.. "expected "
						.. repr(expected)
						.. ", got "
						.. repr(actual),
					2
				)
			end
		end,
		ok = function(value: any, msg: string?)
			if not value then
				error((msg and (msg .. ": ") or "") .. "expected truthy, got " .. repr(value), 2)
			end
		end,
	}
	body(s)
	table.insert(groups, group)
end

-- Runs every registered suite; returns passed, failed and one message per failure.
function M.run(): (number, number, { string })
	local passed, failed = 0, 0
	local failures: { string } = {}
	for _, group in groups do
		for _, case in group.cases do
			local ok, err = pcall(case.fn)
			if ok then
				passed += 1
			else
				failed += 1
				table.insert(failures, group.name .. " › " .. case.name .. "\n    " .. tostring(err))
			end
		end
	end
	return passed, failed, failures
end

return M
