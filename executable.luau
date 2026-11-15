--!strict
local cache: { [string]: string } = {}

-- The env override wins; else the first existing install path; else the bare name. Memoized per tool.
local function find(name: string, override: string, home_dirs: { string }, system_dirs: { string }): string
	local cached = cache[name]
	if cached then return cached end
	local path = tern.getenv(override)
	if not path or path == "" then
		local candidates = {}
		local home = tern.getenv("HOME")
		if home and home ~= "" then
			local root = string.gsub(home, "/+$", "")
			for _, dir in home_dirs do table.insert(candidates, root .. dir .. "/" .. name) end
		end
		for _, dir in system_dirs do table.insert(candidates, dir .. "/" .. name) end
		path = name
		for _, candidate in candidates do
			if tern.fs.exists(candidate) then
				path = candidate
				break
			end
		end
	end
	cache[name] = path
	return path
end

local function omp_bin(): string
	return find("omp", "OMP_BIN", { "/.local/bin", "/.bun/bin" }, { "/opt/homebrew/bin", "/usr/local/bin" })
end

local function tern_bin(): string
	return find("tern", "TERN_BIN", { "/.local/bin" }, { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin" })
end

return { tern_bin = tern_bin, omp_bin = omp_bin }
