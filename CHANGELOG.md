# Changelog

## 0.1.8

- Switchboard keeps a durable tree history in kv: every project, each tab's split layout, and every pane's omp session id. When a daemon reset or update drops projects, a "Restore saved tree" banner and the palette command `Switchboard: restore saved tree` recreate the projects, rebuild tabs that contain agents with their splits and resume those agents (bounded to 15 tabs and 12 agents, the rest stay resumable Closed cards); shell-only layouts are skipped.
- Each workspace shows a parked-pane badge when Tern has parked panes whose folder belongs there. Hovering (or clicking) the badge opens a card of rich rows in Tern's own terms: kind icon, block title and kind · folder; choosing one switches to that workspace and unparks the pane.
- The footer launcher row keeps your custom plugin shortcuts, scrolls sideways like the quota row, and separates two fixed slots: a grid button that opens a hover card, and the add button. The card lays built-in Tern blocks (task manager, board, git, browser, screen, agent, shell, notebook, note, database, canvas, Carly) out as three vertical category columns of square icon tiles instead of one long list. Built-in blocks open as centered overlay windows with a dimmed backdrop: Git uses Tern's own glimpse, and the rest (task manager, board, screen, shell, agent, browser, notebook, …) are opened, floated, and restyled into a centered card by a plugin style sheet. The float header stays on top: "Expand picture in picture" (⇧⌘↵) fills the block area, "Return to split" makes the card a tiled block, and "Close block" ends it; the style is dropped as soon as it leaves the float.
- Agent todo bars no longer vanish when the todo tool call scrolls out of the short transcript window: a missing list gets a deeper read now and then and is carried forward until a new turn starts.
- The Agents header bell shows Tern's native inbox count (the panes with an unseen alert) as a badge; a click still opens the inbox.
- When Tern has a downloaded build waiting for a restart, an update icon appears in the header; a click runs Tern's own Restart to Update. The icon follows Tern's `ready` field in its update state, not leftover download folders.

## 0.1.7

- Renders no longer trip Tern's 50 ms budget: `tern.ui.el` copies its whole child subtree on every call, so the nested containers over all cards cost 30-185 ms of Lua per render. Containers now take their children by reference. This was why a resumed or new session sometimes appeared only after switching tabs.
- A session no longer shows twice (live and closed): a record made before the session id was known merges into the session record with the same name and folder, and every duplicate session is merged on update.
- A new agent on a reused pane id and folder no longer takes over a closed session's history record.
- Tabs opened for a project or a resumed session no longer land in the previous workspace: the workspace switch applies a frame late, so the tab now opens on the next tick. Resume also opens in the workspace that owns the session's folder.

## 0.1.6

- Fix the "duplicate child key closed:…" popup: a session recorded twice in history now merges to its oldest entry, and the sidebar renders each closed session once.

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
