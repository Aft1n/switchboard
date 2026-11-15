# Changelog

## 0.1.1

- Fix agent cards stuck on "loading" (one re-reading pane starved the rest) and show an idle agent's last real steps when its newest turn used no tools.
- Keep window callbacks under Tern's 50 ms budget: render on its own tick, native JSON for `tern inspect`, sidebar updates go to the visible tab first.
- Subagent dropdown opens and closes correctly; notifications only while Tern is in the background.

## 0.1.0 (initial release)

- Workspace and agent sidebar for Tern: workspaces with tabs, agents with state labels, a pinned focused workspace tab, instant subagent disclosure, keyboard shortcuts.
- Live omp steps, todos and subagents in each agent card.
- Other coding harnesses in terminal panes (Claude Code, Codex, pi, OpenCode, Grok Build and similar), best-effort: local panes by a process scan, remote panes by their titles. States come from screen activity. Brand icons appear before titles.
- Provider quota rings from `omp usage`, with a status-bar segment that refreshes them.
- Host-aware routing: workspaces follow the host chip, agents are listed together, and actions switch to the owning host first.
- Notifications on macOS when Tern is not frontmost.
