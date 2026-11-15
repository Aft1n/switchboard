-- Pure parser for `tern inspect --json`: the durable omp session behind each pane.
-- Tern pane ids are ephemeral (reused by other agents, lost on restore); the
-- session file id is the identity history keeps across relaunches. Titles are
-- parsed too: OMP /new swaps the session in the same pane and the title change
-- is what makes the swap visible before the 30 s fallback.
local M = {}

local function unescape(text)
	return (string.gsub(text, "\\(.)", function(char)
		if char == "n" then return "\n" end
		if char == "r" then return "\r" end
		if char == "t" then return "\t" end
		return char
	end))
end

-- Maps pane strings to {session=omp session id, cwd=..., title=...} for panes
-- whose omp_session_file is a non-empty path. Line-based: the whole pretty JSON
-- is never decoded here, so a huge pane arg line cannot affect the result.
function M.parse(stdout)
	local out = {}
	if type(stdout) ~= "string" then return out end
	local in_panes = false
	local pane, cwd, session, title, file
	for line in string.gmatch(stdout .. "\n", "([^\n]*)\n") do
		if not in_panes then
			if string.match(line, '^  "panes": %[$') then in_panes = true end
		elseif string.match(line, '^  %][,]?$') then
			break
		else
			local id = string.match(line, '^      "pane": (%d+),?$')
			if id then
				pane, cwd, session, title, file = id, nil, nil, nil, nil
			elseif pane then
				local value = string.match(line, '^      "cwd": "([^"]*)"')
				if value then cwd = unescape(value) end
				value = string.match(line, '^      "title": "(.*)"')
				if value then title = unescape(value) end
				value = string.match(line, '^      "omp_session_file": "([^"]*)"')
				if value and value ~= "" then
					file = unescape(value)
					value = string.match(file, "([%w%-]+)%.jsonl$")
					if value then session = value end
				end
				if string.match(line, '^    }[,]?$') then
					if session then out[pane] = {session=session, cwd=cwd or "", title=title, file=file} end
					pane, cwd, session, title, file = nil, nil, nil, nil, nil
				end
			end
		end
	end
	return out
end

-- True when the same pane started a different OMP session in the same cwd.
function M.new_session(old, new)
	if type(old) ~= "table" or type(new) ~= "table" then return false end
	local before, after = old.session, new.session
	if type(before) ~= "string" or before == "" or type(after) ~= "string" or after == "" then return false end
	return before ~= after and (old.cwd or "") == (new.cwd or "")
end

-- Pane keys whose session started over in the same cwd, for the window to move.
function M.new_sessions(old, new)
	local out = {}
	if type(old) ~= "table" or type(new) ~= "table" then return out end
	for pane, mapping in new do
		if M.new_session(old[pane], mapping) then table.insert(out, pane) end
	end
	table.sort(out)
	return out
end

-- Shell command that resumes `session`, nil when the id or executable is unsafe.
function M.resume_command(executable, session)
	if type(executable) ~= "string" or executable == "" then return nil end
	if type(session) ~= "string" or not string.match(session, "^[%w%-]+$") then return nil end
	return string.format("%q --resume %s", executable, session)
end

-- Same mapping as `parse`, from an already decoded `tern inspect --json` value.
-- Returns nil when the shape is not what inspect emits; the caller then falls back to `parse`.
function M.from_decoded(value)
	if type(value) ~= "table" or type(value.panes) ~= "table" then return nil end
	local out = {}
	for _, pane in value.panes do
		local file = type(pane) == "table" and pane.omp_session_file
		if type(file) == "string" and file ~= "" and type(pane.pane) == "number" then
			local session = string.match(file, "([%w%-]+)%.jsonl$")
			if session then
				local key = string.format("%.0f", pane.pane)
				out[key] = {session=session, cwd=if type(pane.cwd) == "string" then pane.cwd else "", title=if type(pane.title) == "string" then pane.title else nil, file=file}
			end
		end
	end
	return out
end

return M
