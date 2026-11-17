# Changelog

## 0.1.6  - Fix the "duplicate child key closed:…" popup: a session recorded twice in history now merges to its oldest entry, and the sidebar renders each closed session once. 
## 0.1.5

- Agent cards have a close x on hover that closes the agent's tab, like the x on workspace tab rows. Right-click "Close block" on the sidebar still closes the sidebar itself: Tern's menu names no row.

## 0.1.4

- Fix sessions that vanish or open wrong after a Tern budget pause: while the timer hook is paused (up to 5 min), clicks and new tabs repaint the sidebar from the click or event itself instead of waiting on a timer, and a pending focus retry no longer fires minutes late.
- A resync no longer serves the tree built for a background tab's prewarm.
- Sidebar cards carry their slot key, so incremental patches match (every card change used to fall back to a full resync). A patch only goes to a pane that saw the previous render; quota changes send the full tree.
- A repaint with nothing changed builds no `tern.ui` nodes and reuses the encoded tree. Each `tern.ui` call took 1-100 ms live, so the 2 s heartbeat render ran 40-400 ms and tripped Tern's 50 ms timer budget.
- Steps over 40 ms are logged as `switchboard: slow <step>` in tern.log.

## 0.1.3

- Sidebar updates are incremental: a block gets only the cards that changed (a few KB) with a full-tree resync fallback, and only the visible tab's sidebar is kept in sync.
- Repaints are cheaper: styles apply only when they change, background sidebars are not re-pushed, same-tab clicks do no window work, and card projects name the folder the agent runs in.
- Clicking an agent card always selects it: the block flips the highlight locally, the window confirms the authoritative pane, and a focus that lands a frame late is retried.
- Each card is memoized by its own inputs, so a poll or click rebuilds only the cards that changed.
- Fewer timers and child processes: one timer chain removed, subagent reads at 3 s per agent, process scan at 10 s, isolation scan at 5 min.

## 0.1.2

- OMP vibe workers from `vibe_spawn`/`vibe_wait` results appear in the agent card's subagent list, read from the session file at most every 4 s; clicking one opens its thread.
- `/new` in OMP replaces the session in the same pane again: no tab moves, no resume. The previous session goes to Closed and the pane's card resets.
- Title, cwd and focus events only mark the window dirty; the next poll refreshes it and an idle heartbeat refreshes it every 5 s, which stops Tern's 50 ms budget pauses that left cards on "Loading activity…".

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
