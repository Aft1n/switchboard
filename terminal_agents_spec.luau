local h = require("./spec/harness")
local agents = require("./terminal_agents")

local TRUST = "Do you want to trust the files in this folder?\n❯ No, exit\n  Yes, I trust this folder\n  Enter to confirm · Esc to cancel"
local IDLE = "> \n? for shortcuts"
local SPINNER = "\226\160\139" -- U+280B, a braille spinner frame

h.suite("terminal agents", function(s)
	s.test("scan output maps known harness panes and drops unknown keys", function()
		s.eq(agents.parse_scan("12345 claude\n23456 pi\n34567 vim\n\n"), { [12345] = "claude", [23456] = "pi" })
		s.eq(agents.parse_scan(""), {})
	end)

	s.test("a running command's basename identifies the harness", function()
		s.eq(agents.classify_title("zsh", "/usr/local/bin/codex --resume"), "codex")
	end)

	s.test("each remote title form identifies its harness", function()
		s.eq(agents.classify_title("OpenCode v1.2", nil), "opencode")
		s.eq(agents.classify_title("OC | build", nil), "opencode")
		s.eq(agents.classify_title("π - ~/proj", nil), "pi")
		s.eq(agents.classify_title("✳ Claude Code", nil), "claude")
		s.eq(agents.classify_title(SPINNER .. " Claude working", nil), "claude")
	end)

	s.test("titles without a harness signature are not classified", function()
		s.eq(agents.classify_title("vim notes.md", nil), nil)
		s.eq(agents.classify_title("Claude Code", nil), nil)
	end)

	s.test("clean_title falls back to the label for titles that name no session", function()
		s.eq(agents.clean_title("", "claude", "/tmp/x"), "Claude Code")
		s.eq(agents.clean_title("zsh", "claude", "/tmp/x"), "Claude Code")
		s.eq(agents.clean_title("x", "claude", "/home/me/x/"), "Claude Code")
		s.eq(agents.clean_title("me@laptop:~/x", "claude", "/tmp/x"), "Claude Code")
		s.eq(agents.clean_title("claude", "claude", "/tmp/x"), "Claude Code")
	end)

	s.test("clean_title strips harness glyphs and keeps the real title", function()
		s.eq(agents.clean_title("✳ Fix parser", "claude", "/tmp/x"), "Fix parser")
		s.eq(agents.clean_title(SPINNER .. " Refactor", "claude", "/tmp/x"), "Refactor")
		s.eq(agents.clean_title("π - notes", "pi", "/tmp/x"), "notes")
		s.eq(agents.clean_title("OC | build", "opencode", "/tmp/x"), "build")
	end)

	s.test("trust and y/n prompts need input; an idle prompt does not", function()
		s.ok(agents.needs_input(TRUST))
		s.ok(agents.needs_input("Continue? (y/n)"))
		s.eq(agents.needs_input(IDLE), false)
	end)

	s.test("first sight of a static screen is idle", function()
		s.eq(agents.state(nil, IDLE, 0).state, "idle")
	end)

	s.test("a changed screen is working for 2500 ms, then idle while unchanged", function()
		local first = agents.state(nil, IDLE, 0)
		local changed = agents.state(first, "> build\n? for shortcuts", 1000)
		s.eq(changed.state, "working")
		s.eq(agents.state(changed, "> build\n? for shortcuts", 3499).state, "working")
		s.eq(agents.state(changed, "> build\n? for shortcuts", 3500).state, "idle")
	end)

	s.test("an unchanged screen keeps the timestamp of its last change", function()
		local first = agents.state(nil, IDLE, 0)
		local changed = agents.state(first, "> build", 1000)
		local same = agents.state(changed, "> build", 3600)
		s.eq(same.changed_at, 1000)
	end)

	s.test("a prompt on screen overrides working", function()
		local first = agents.state(nil, IDLE, 0)
		s.eq(agents.state(first, TRUST, 1000).state, "waiting_input")
	end)
end)

return true
