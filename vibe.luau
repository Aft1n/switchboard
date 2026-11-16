-- OMP vibe mode (vibe_spawn / vibe_wait / vibe_send) keeps its named workers in the tool results'
-- `details.screens`, which Tern's transcript does not carry. They are read from the end of the omp
-- session file and fed to subagents.scan as if they were task metadata.
local M = {}

-- argv that prints the last session-file lines holding vibe tool results (path is $1, never interpolated).
function M.command(file)
	return {"/bin/sh", "-c", 'tail -n 400 "$1" | grep \'"toolName":"vibe_\'', "sh", file}
end

-- Synthetic transcript messages from those lines; `decode` is tern.json.decode.
function M.messages(stdout, decode)
	local out = {}
	if type(stdout) ~= "string" then return out end
	for line in string.gmatch(stdout, "[^\n]+") do
		local ok, entry = pcall(decode, line)
		local message = ok and type(entry) == "table" and entry.type == "message" and entry.message
		if type(message) == "table" and message.role == "toolResult" and type(message.toolName) == "string"
			and string.find(message.toolName, "^vibe_") and type(message.details) == "table"
			and type(message.details.screens) == "table" then
			table.insert(out, {role = "assistant", tools = {{name = message.toolName, metadata = {screens = message.details.screens}}}})
		end
	end
	return out
end

-- True when a transcript used vibe tools, so the session file is worth reading.
function M.used(messages)
	for _, message in (if type(messages) == "table" then messages else {}) do
		for _, tool in (if type(message) == "table" and type(message.tools) == "table" then message.tools else {}) do
			if type(tool) == "table" and type(tool.name) == "string" and string.find(tool.name, "^vibe_") then return true end
		end
	end
	return false
end

return M
