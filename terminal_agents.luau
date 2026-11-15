-- Best-effort detection of coding harnesses (Claude Code, Codex, pi, ...) that run as
-- plain terminal panes. Local panes are found by a process scan; remote panes by title.
local M = {}

local NAMES = {
	claude="Claude Code", codex="Codex", pi="pi", opencode="OpenCode", opencode2="OpenCode 2", grok="Grok Build",
	gemini="Gemini CLI", aider="Aider", amp="Amp", goose="Goose", crush="Crush", droid="Droid",
	["cursor-agent"]="Cursor Agent", kimi="Kimi", qwen="Qwen Code",
}
-- Tern's built-in brand icons; harnesses without one get a monogram or a generic mark in the view.
M.ICONS = {
	claude="provider-anthropic", codex="provider-openai-codex", opencode="provider-opencode", opencode2="provider-opencode",
	grok="provider-xai", gemini="provider-google-gemini-cli", ["cursor-agent"]="provider-cursor",
	kimi="provider-kimi-code", qwen="provider-qwen-portal",
}
M.MONOGRAMS = {pi="π"}
local SHELLS = {zsh=true, bash=true, fish=true, sh=true, pwsh=true, cmd=true}
local PROMPTS = {"Enter to confirm", "Yes, I trust this folder", "No, exit", "Do you want to",
	"(y/n)", "(Y/n)", "[y/N]", "[Y/n]", "Press enter to continue", "Esc to cancel"}
local BRAILLE = "\226[\160-\163][\128-\191]"
-- A screen that changed this recently counts as running; reads are only a few seconds apart.
local RUNNING_MS = 2500

-- Prints "<pane> <harness>" for each harness process. The harness is argv[0] (or argv[1]
-- under node/bun/python) by basename; its pane is the nearest ancestor, itself included,
-- whose environment has TERN_PANE. Only argv tokens are checked for exclusions, since the
-- environment follows the command on the same line.
M.SCAN = [==[
/bin/ps -Eww -ax -o pid=,ppid=,command= | awk '
BEGIN {
  n = split("claude codex pi opencode opencode2 grok gemini aider amp goose crush droid cursor-agent kimi qwen", names, " ")
  for (i = 1; i <= n; i++) H[names[i]] = 1
  R["node"] = 1; R["bun"] = 1; R["python"] = 1; R["python3"] = 1
}
{
  pid = $1; pp[pid] = $2
  if (match($0, /TERN_PANE=[0-9]+/)) pn[pid] = substr($0, RSTART + 10, RLENGTH - 10)
  a = $3; sub(".*/", "", a)
  b = $4; sub(".*/", "", b)
  k = ""
  if (a in H) k = a
  else if ((a in R) && (b in H)) k = b
  args = $3 " " $4 " " $5 " " $6
  if (k != "" && $2 != 1 && args !~ /app-server|mcp|--acp|serve/) hk[pid] = k
}
END {
  for (p in hk) {
    q = p; pane = ""
    for (d = 0; d < 40 && q != "" && q != "0"; d++) {
      if (q in pn) { pane = pn[q]; break }
      q = pp[q]
    }
    if (pane != "" && !(pane in done)) { done[pane] = 1; print pane, hk[p] }
  }
}'
]==]

function M.parse_scan(stdout)
	local found = {}
	for pane, key in string.gmatch(stdout, "(%d+) (%S+)") do
		if NAMES[key] then found[tonumber(pane)] = key end
	end
	return found
end

function M.label(key)
	return NAMES[key] or "Agent"
end

local function command_name(line)
	local word = string.match(line or "", "^%s*(%S+)")
	return if word then string.match(word, "([^/]+)$") else nil
end

-- Remote panes have no process scan: the running command or a harness-specific title marks them.
function M.classify_title(title, running_line)
	local word = command_name(running_line)
	if word and NAMES[word] then return word end
	title = title or ""
	word = command_name(title)
	if word and NAMES[word] then return word end
	if string.sub(title, 1, #"π - ") == "π - " then return "pi" end
	if string.find(title, "^OpenCode") or string.sub(title, 1, #"OC | ") == "OC | " then return "opencode" end
	if string.find(title, "Claude", 1, true) and (string.find(title, "✳", 1, true) or string.find(title, BRAILLE)) then
		return "claude"
	end
	return nil
end

-- Strips harness glyphs; a shell, prompt, or bare directory title is not a name, so it
-- falls back to the harness label.
function M.clean_title(title, key, cwd)
	local name = title or ""
	name = string.gsub(name, "^" .. BRAILLE .. "%s*", "")
	name = string.gsub(name, "^✳%s*", "")
	name = string.gsub(name, "^π %- ", "")
	name = string.gsub(name, "^OC | ", "")
	name = string.match(name, "^%s*(.-)%s*$")
	local base = if cwd then string.match(cwd, "([^/]+)/*$") else nil
	if name == "" or SHELLS[name] or name == key or name == NAMES[key] or name == base
		or string.find(name, "@", 1, true) then
		return M.label(key)
	end
	return name
end

function M.needs_input(text)
	for _, prompt in PROMPTS do
		if string.find(text, prompt, 1, true) then return true end
	end
	return false
end

-- `prev` is the last record for the pane ({text, changed_at, state}). A screen counts as
-- running while its text keeps changing; a first sight is idle until it changes.
function M.state(prev, text, now)
	local changed_at = -math.huge
	if prev then changed_at = if prev.text == text then prev.changed_at else now end
	local state = "idle"
	if M.needs_input(text) then state = "waiting_input"
	elseif now - changed_at < RUNNING_MS then state = "working" end
	return {text=text, changed_at=changed_at, state=state}
end

return M
