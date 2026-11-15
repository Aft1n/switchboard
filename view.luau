local arc = require("./arc")
local progress = require("./progress")
local usage = require("./usage")
local section_sizes = require("./section_sizes")
local project_colors = require("./project_colors")
local terminal_agents = require("./terminal_agents")
local M = {}
-- Tern icons standing in for omp's per-tool glyphs; unknown tools keep the status mark.
local TOOL_ICONS = {
	bash="terminal", read="file", write="file-plus", edit="pen", glob="folder-open", find="search",
	grep="search", ast_grep="search", ast_edit="wand", web_search="globe", fetch="globe", browser="globe",
	todo="list-checks", task="users", wait="timer", lsp="code", eval="code", github="branch",
}

local LABELS = {working="Running", waiting_input="Needs input", idle="Idle", done="New result"}
local PROVIDER_NAMES = {["openai-codex"]="Codex", anthropic="Claude", ["google-antigravity"]="Gemini", commandcode="Command"}
local PROVIDER_LOGOS = {anthropic="provider-anthropic", ["openai-codex"]="provider-openai", ["google-antigravity"]="provider-google"}
local ACTIVITY_LABELS = {loading="Loading activity…", unavailable="Activity unavailable", unreported="Activity not reported", no_tools="No tool steps yet", terminal="Terminal agent"}
local SUBAGENT_STATES = {working=true, waiting_input=true, idle=true, done=true, failed=true, closed=true}
-- Unreserved URI characters pass through; the rest become %XX in agent ids and SVG data URIs.
local function percent_encode(value)
	return (string.gsub(tostring(value), "[^%w%-._~]", function(char) return string.format("%%%02X", string.byte(char)) end))
end

function M.render(ui, data, focused)
	local settings = data.sidebar_settings or {}
	local show_closed = settings.closed ~= false
	local show_steps = settings.steps ~= false
	local show_hosts = settings.hosts ~= false
	local show_quotas = settings.quotas ~= false
	local function el(tag, class, children, text, action)
		return ui.el(tag, {class=if class == "switchboard" then "switchboard cp-live-" .. (if data.sidebar_pane then string.format("%.0f",data.sidebar_pane) else "preview") else class, text=text, key=if action then string.gsub(action,":","-") else nil,
			attrs=if action == "new-workspace" then {["aria-label"]="Create workspace", title="Create workspace"} elseif class == "switchboard" then {["data-switchboard-host"]=tostring(data.sidebar_host or "preview"),["data-switchboard-pane"]=tostring(data.sidebar_pane or "preview")} else nil,
			actions=if action then {click=action} else nil}, children)
	end
	local function text(class, value) return el("span", class, nil, value) end
	local function project_text(name, base)
		name = name or ""
		local color = (data.project_colors or {})[name]
		local color_class = project_colors.class(color)
		return text(base .. (if color_class then " " .. color_class else ""), name)
	end
	local function icon(name, class)
		return el("span", class, {ui.node("icon", {name=name})})
	end
	local function keyed(node, key)
		node.p.key = key
		return node
	end
	-- Tern's own brand icons mark non-omp harnesses; omp rows keep the glyph in their title.
	local function harness_mark(key)
		local name = terminal_agents.ICONS[key]
		if name then return icon(name, "cp-harness") end
		local mono = terminal_agents.MONOGRAMS[key]
		if mono then return text("cp-harness cp-harness-mono", mono) end
		return icon("sparkle", "cp-harness")
	end
	local function miniature(tree, share)
		if tree.pane then
			return ui.el("div", {class="cp-mini-leaf" .. (if tree.pane == focused then " cp-mini-focused" else ""),grow=share,key=tostring(tree.pane)})
		end
		return ui.el("div", {class="cp-mini-box " .. (if tree.split == "down" then "cp-mini-col" else "cp-mini-row"),grow=share}, {
			miniature(tree[1],tree.ratio),miniature(tree[2],1-tree.ratio),
		})
	end
	local projects = {}
	local lift_id = data.workspace_lift
	local lift_name
	for _, item in data.projects do
		if tostring(item.id) == lift_id then lift_name = item.name; break end
	end
	-- Workspaces follow the host chip; agents stay unified across hosts.
	local shown = {}
	for _, p in data.projects do
		if not data.host or p.host == nil or p.host.id == data.host.id then table.insert(shown, p) end
	end
	for _, p in shown do
		local workspace_key = tostring(p.id)
		local expanded = #p.tabs > 0 and (if data.workspace_expanded and data.workspace_expanded[workspace_key] ~= nil
			then data.workspace_expanded[workspace_key] else p.current == true
		)
		local picked = tostring(p.id) == lift_id
		-- Keep the normal click action: the window treats a click while a workspace
		-- is picked up as the drop, so a stale block tree cannot swallow the move.
		local row_action = (if #p.tabs == 0 then "select-workspace:" else "fold-workspace:") .. workspace_key
		local project = el("button", "cp-project" .. (if (p.busy_tabs or 0)>0 then " cp-workspace-busy" else "") .. (if p.current then " cp-current" else "") .. (if expanded then " cp-open" else ""), {
			icon("folder", "cp-project-icon"),
			project_text(p.name, "cp-label cp-project-name"), text("cp-count", (if (p.busy_tabs or 0)>0 then tostring(p.busy_tabs) .. " active · " else "") .. tostring(#p.tabs) .. (if #p.tabs == 1 then " tab" else " tabs")),
			icon("chev-r","cp-workspace-chevron"),
		}, nil, row_action)
		project.p.attrs = {["aria-current"]=if p.current then "true" else "false",["aria-expanded"]=if expanded then "true" else "false"}
		project.p.title = if lift_id
			then (if picked then "Cancel moving " .. p.name else "Move " .. (lift_name or "workspace") .. " here")
			else (if #p.tabs == 0 then "Select project · ⌘T to open a tab" else (if expanded then "Collapse " else "Expand ") .. p.name)
		local grip = el("button", "cp-workspace-grip", nil, "⠿", "lift-workspace:" .. workspace_key)
		grip.p.title = if picked then "Cancel move" else "Pick up to move, then click where it goes"
		grip.p.aria = if picked then "Cancel moving " .. p.name else "Move " .. p.name
		-- Classes, not attrs: Tern's view drops arbitrary attributes, so CSS never saw them.
		local drop = if lift_id and not picked then " cp-drop-target" else ""
		local row_children = {project, grip}
		if drop ~= "" then table.insert(row_children, text("cp-drop-hint", "Drop here")) end
		table.insert(row_children, ui.button("", {
			icon="x", title="Close workspace", aria="Close workspace " .. p.name,
			role="switchboard.workspace-close", variant="quiet", size="sm",
			actions={click="close-workspace:" .. workspace_key},
		}))
		local project_row = ui.el("div", {class="cp-project-row" .. (if picked then " cp-picked" else "") .. drop, key="project-row" .. workspace_key}, row_children)
		table.insert(projects, project_row)
		if expanded then
			for _, t in p.tabs do
				local tab_key = string.format("%.0f",t.id)
				local copy = {text("cp-tab-title",t.name)}
				if t.secondary then table.insert(copy,text("cp-tab-secondary",t.secondary)) end
				local children = {text("cp-branch","·"),el("div","cp-tab-copy",copy)}
				if t.layout then
					local shapes = {miniature(t.layout,1)}
					if (t.floats or 0) > 0 then table.insert(shapes, el("div","cp-mini-float")) end
					table.insert(children,ui.el("div",{class="cp-mini",attrs={["aria-hidden"]="true"}},shapes))
				end
				
				local button = el("button", "cp-tab" .. (if t.pane == focused then " cp-selected" else ""),children,nil,"pane:" .. string.format("%.0f",t.pane))
				button.p.key="tab" .. tab_key
				button.p.title = t.name .. " · " .. tostring(t.pane_count or 1) .. " panes"
				button.p.aria = button.p.title
				button.p.attrs = {["aria-pressed"]=if t.pane == focused then "true" else "false"}
				local close = ui.button("", {
					icon="x", title="Close tab", aria="Close " .. t.name,
					role="switchboard.tab-close", variant="quiet", size="sm",
					actions={click="close-tab:" .. tab_key},
				})
				close.p.key="close-tab" .. tab_key
				table.insert(projects, ui.el("div", {class="cp-tab-row",key="tab-row" .. tab_key}, {button,close}))
			end
		end
	end
	if #projects == 0 then table.insert(projects, el("p", "cp-empty", nil, "No workspaces open")) end
	local agents = {}
	local function render_agent(a)
		local p = a.progress
		local subagents = a.subagents or {}
		local todo=progress.visible_todo(p,a.state,a.progress_completed_at,data.now)
		-- A parent with subagents keeps its last todo bar as history; the time hide
		-- would remove the very row the disclosure sits beside.
		if not todo and #subagents > 0 and p and p.todo then todo = p.todo end
		local state_label = if a.state == "idle" and (a.finished or (a.finished_at or 0) > 0) then "Finished" else (LABELS[a.state] or a.state)
		local metadata = {}
		if a.host and show_hosts then
			local badge=el("span","cp-agent-host cp-agent-host-" .. a.host.kind .. (if a.host.state~="connected" then " cp-agent-host-offline" else ""))
			badge.p.attrs={["aria-label"]=(if a.host.kind=="local" then "Local" else "Remote") .. " host · " .. a.host.name}
			table.insert(metadata,badge)
		end
		table.insert(metadata,project_text(a.project,"cp-agent-project"))
		if a.isolation then
			local iso=a.isolation
			local badge=text("cp-agent-isolation cp-agent-isolation-" .. iso.kind .. (if iso.dirty then " cp-agent-isolation-dirty" else ""), iso.kind)
			badge.p.title=(if iso.kind == "co" then "Checkout" else "Worktree") .. ": " .. iso.name .. " · " .. iso.detail
			badge.p.attrs={["aria-label"]=badge.p.title}
			table.insert(metadata,badge)
		end
		if a.model then table.insert(metadata,text("cp-agent-model",a.model)) end
		local top = {}
		if a.harness then table.insert(top, harness_mark(a.harness)) end
		table.insert(top, text("cp-label", a.name))
		table.insert(top, el("div", "cp-agent-status", {
			(if a.state == "working" then keyed(el("span","cp-working-orbit",{el("span","cp-orbit-core")}),"orbit") else text("cp-dot", "●")),
			text("cp-state", state_label),
		}))
		local children = {
			el("div", "cp-agent-top", top),
			el("div", "cp-agent-bottom",metadata),
		}
		local step_node
		if show_steps and p and #p.steps > 0 then
			local step = p.steps[#p.steps]
			local mark = TOOL_ICONS[step.tool or ""] or (if step.status == "failed" then "error" elseif step.status == "running" then "timer" elseif step.status == "done" then "check" else "minus")
			step_node = el("div","cp-step cp-step-" .. step.status,{icon(mark,"cp-step-icon"),text("cp-step-label",step.label)})
		elseif show_steps and (a.activity_status or a.unavailable) then
			local label = ACTIVITY_LABELS[a.activity_status] or "Activity unavailable"
			step_node = text("cp-activity-label",label)
		end
		if step_node then table.insert(children, step_node) end
		if todo then
			local count = tostring(todo.done) .. " / " .. tostring(todo.total)
			local count_node = text("cp-progress-count", count)
			count_node.p.title = tostring(todo.done) .. " of " .. tostring(todo.total) .. " tasks done"
			local meter = ui.node("meter", {
				value=todo.done/todo.total, size="sm", role="switchboard.progress", tone="accent",
				aria=count .. " tasks completed",
			})
			table.insert(children, el("div", "cp-agent-progress", {meter, count_node}))
		end
		local pane_key=string.format("%.0f",a.pane)
		local agent = el("button", "cp-card-agent" .. pane_key .. " cp-agent cp-" .. a.state .. (if a.pane == focused then " cp-agent-selected" else ""), children, nil, "pane:" .. pane_key)
		local hint={a.name}
		if a.host then table.insert(hint,(if a.host.kind=="local" then "Local · " else "Remote · ") .. a.host.name) end
		if a.cwd and a.cwd~="" then table.insert(hint,a.cwd) end
		if p and #p.steps>0 then
			for i=math.max(1,#p.steps-2),#p.steps do
				local step=p.steps[i]
				table.insert(hint,(if step.status=="running" then "◌ " elseif step.status=="failed" then "× " else "✓ ") .. step.label)
			end
		end
		agent.p.title=table.concat(hint,"\n")
		agent.p.key="agent" .. pane_key
		agent.p.aria = a.name .. " · " .. state_label .. (if a.host then " · " .. a.host.kind .. " · " .. a.host.name else "")
		agent.p.attrs = {["aria-pressed"]=if a.pane == focused then "true" else "false"}
		if #subagents == 0 then return agent end

		local parent_pane = pane_key
		local expanded = data.subagents_expanded and data.subagents_expanded[parent_pane] == true
		local running = 0
		for _, child in subagents do
			if child.state == "working" or child.state == "waiting_input" then running += 1 end
		end
		local summary = tostring(#subagents) .. (if running > 0 then " · " .. tostring(running) .. " running" else "")
		local toggle = el("button", "cp-subagent-toggle" .. (if expanded then " cp-subagent-open" else ""), {
			el("span", "cp-subagent-bot"),
			text("cp-subagent-label", summary),
			icon("chev-r", "cp-subagent-chevron"),
		}, nil, "subagents:" .. parent_pane)
		toggle.p.key = "subagents-toggle" .. parent_pane
		toggle.p.title = (if expanded then "Hide " else "Show ") .. tostring(#subagents) .. " subagents"
		toggle.p.aria = (if expanded then "Hide " else "Show ") .. tostring(#subagents) .. " subagents for " .. a.name
		toggle.p.attrs = {["aria-expanded"]=if expanded then "true" else "false"}
		local branch_children = {toggle}
		-- Children always render; CSS shows them while the toggle is open, so the sidebar block can
		-- flip the disclosure locally without waiting for the window to rebuild the tree.
		do
			local child_cards = {}
			for _, child in subagents do
				local child_title = child.title or child.name or (if child.id ~= nil then "Subagent " .. tostring(child.id) else "Subagent")
				local child_state = child.state or "Unknown"
				-- OMP writes its task spawn result once with pending rows and never
				-- updates it. Show those rows as closed history, not live queued workers.
				local display_state = if child_state == "queued" then "closed" else child_state
				local child_state_label = if display_state == "closed" then "Closed" else LABELS[child_state] or child_state
				local state_class = if SUBAGENT_STATES[display_state] then display_state else "other"
				local latest = child.error or child.latest_step or child.step or child.summary or child.result
				if type(latest) == "table" then latest = latest.label or latest.text or latest.summary end
				local detail = {}
				if child.model and child.model ~= "" then table.insert(detail, child.model) end
				if latest and latest ~= "" then table.insert(detail, tostring(latest)) end
				local child_content = {
					el("div", "cp-subagent-top", {
						text("cp-subagent-name", child_title), text("cp-subagent-state cp-subagent-state-" .. state_class, child_state_label),
					}),
				}
				if #detail > 0 then table.insert(child_content, text("cp-subagent-detail", table.concat(detail," · "))) end
				local action = if display_state == "closed" then nil
					elseif child.pane ~= nil then "pane:" .. string.format("%.0f",child.pane)
					elseif child.id ~= nil then "subagent:" .. parent_pane .. ":" .. percent_encode(child.id)
					else nil
				local child_class="cp-subagent-card" .. (if display_state=="idle" or display_state=="failed" or display_state=="closed" then " cp-subagent-muted" else "")
				local child_card = if action then el("button", child_class, child_content, nil, action)
					else el("div", child_class, child_content)
				child_card.p.key = "subagent" .. parent_pane .. (if child.id ~= nil then percent_encode(child.id) else child_title)
				child_card.p.title = child_title .. " · " .. child_state_label
				if action then child_card.p.aria = child_title .. " · " .. child_state_label .. (if #detail > 0 then " · " .. table.concat(detail," · ") else "") end
				table.insert(child_cards, child_card)
			end
			table.insert(branch_children, ui.el("div", {class="cp-subagents", key="subagents" .. parent_pane}, child_cards))
		end
		return ui.el("div", {class="cp-agent-parent-row", key="agent-row" .. parent_pane}, {agent, ui.el("div", {class="cp-subagent-branch", key="subagent-branch" .. parent_pane}, branch_children)})
	end
	for _, a in data.agents do table.insert(agents,render_agent(a)) end
	-- Agents that were seen and have since closed stay in the list, dimmed, until the broom clears them.
	local closed = if show_closed then data.closed or {} else {}
	for i, entry in closed do
		local detail = {project_text(entry.project, "cp-agent-project")}
		if entry.model then table.insert(detail, text("cp-agent-model", entry.model)) end
		-- A closed chat with a known session can be reopened; old history stays inert.
		local resumable = type(entry.session) == "string" and entry.session ~= ""
		local card = el(if resumable then "button" else "div", "cp-agent cp-closed" .. (if resumable then " cp-resumable" else ""), {
			el("div", "cp-agent-top", {
				text("cp-label", entry.name),
				el("div", "cp-agent-status", {text("cp-dot", "●"), text("cp-state", "Closed")}),
			}),
			el("div", "cp-agent-bottom", detail),
		}, nil, if resumable then "resume-session:" .. entry.session else nil)
		-- A reused pane can hold two closed chats, so neither pane nor session alone is unique.
		card.p.key = "closed" .. tostring(i) .. "-" .. tostring(entry.session or entry.pane or "")
		card.p.title = entry.name .. (if entry.cwd and entry.cwd ~= "" then "\n" .. entry.cwd else "") .. (if resumable then "\n· Click to reopen session" else "")
		if resumable then card.p.aria = entry.name .. " · Click to reopen session" end
		table.insert(agents, card)
	end
	if #agents == 0 then table.insert(agents, el("p", "cp-empty", nil, "No agents detected\nAgents appear here when opened in Tern.")) end
	local tools = {text("cp-count",tostring(#data.agents))}
	if #closed > 0 then
		-- Tern ships no broom icon; cp-broom-icon draws one in CSS.
		local broom = el("button", "cp-broom", {el("span", "cp-broom-icon")}, nil, "clear-history")
		broom.p.title = "Clear closed agents"
		broom.p.attrs = {["aria-label"]="Clear closed agents"}
		table.insert(tools, broom)
	end
	table.insert(tools, ui.button("",{icon="bell",title="Tern needs you",aria="Tern needs you",variant="quiet",size="sm",actions={click="inbox"}}))
	local agents_section = {
		el("div", "cp-heading", {text("", "Agents"), el("div","cp-agent-header-tools",tools)}),
		el("div", "cp-summary", {text("cp-live", tostring(data.running) .. " running"),
			text("cp-waiting-count", tostring(data.waiting) .. " need input")}),
		el("div", "cp-agents", agents),
	}
	local launchers = {}
	for i, shortcut in data.shortcuts or {} do
		table.insert(launchers, ui.button("", {
			icon=if shortcut.icon and shortcut.icon ~= "" then shortcut.icon else "plug", title=shortcut.label, aria=shortcut.label,
			variant="quiet",size="sm",actions={click="launch:" .. i},
		}))
	end
	table.insert(launchers, ui.button("", {icon="plus",title="Add or remove plugin shortcuts",aria="Add or remove plugin shortcuts",variant="quiet",size="sm",actions={click="edit-shortcuts"}}))
	local providers, provider_order = {}, {}
	for _, q in (if show_quotas then data.quotas or {} else {}) do
		if not providers[q.provider] then providers[q.provider]={}; table.insert(provider_order,q.provider) end
		table.insert(providers[q.provider],q)
	end
	table.sort(provider_order)
	local host_nodes = {}
	if data.host then
		local h = data.host
		local host = ui.el("button",{class="cp-host",title="Switch Tern host · " .. h.name .. ". Running tasks stay on their original host.",
			attrs={["aria-label"]="Switch host: " .. h.name},actions={click="switch-host"}}, {
			text("cp-host-dot" .. (if h.state == "connected" then " cp-host-connected" else ""),"●"),
			text("cp-host-kind",if h.kind == "local" then "LOCAL" else "VPS"),icon("chev-r","cp-host-chevron"),
		})
		table.insert(host_nodes,host)
	end
	local quota_nodes, quota_sheets, quota_popovers = {}, {}, {}
	for provider_index, provider in provider_order do
		local limits = providers[provider]
		-- Stable window order: short window, long window, then additional quota.
		table.sort(limits,function(a,b) return a.label < b.label end)
		local segments = {}
		local svg = arc.svg(limits)
		local uri = percent_encode(svg)
		table.insert(quota_sheets,'.switchboard .cp-quota-' .. provider_index .. ' .cp-ring { background-image:url("data:image/svg+xml,' .. uri .. '"); }')
		local logo = PROVIDER_LOGOS[provider]
		if logo then table.insert(segments,icon(logo,"cp-ring-monogram"))
		else table.insert(segments,text("cp-ring-monogram",string.upper(string.sub(PROVIDER_NAMES[provider] or provider,1,1)))) end
		local low = false
		for _, q in limits do if not q.stale and q.remaining < 0.1 then low=true; break end end
		if low then table.insert(segments,ui.el("span",{class="cp-limit-alert",text="!",attrs={["aria-label"]="Low quota"}})) end
		local details = {}
		for _, q in limits do
			local percent = math.floor(q.remaining*100+0.5)
			local reading=if q.stale then "Updating…" else tostring(percent) .. "% left"
			table.insert(details,el("div","cp-quota-detail" .. (if not q.stale and q.remaining < 0.1 then " cp-quota-detail-low" else ""),{
				el("div","cp-quota-detail-head",{text("cp-label",q.label),text("cp-quota-percent",reading)}),
				ui.node("meter",{value=q.remaining,size="sm",role="switchboard.quota-meter",tone=if not q.stale and q.remaining < 0.1 then "bad" elseif q.remaining < 0.25 then "warn" else "accent",aria=q.label .. " " .. percent .. "% remaining"}),
				text("cp-quota-reset",if q.stale then "Updating…" else (usage.reset_countdown(q.reset_at,data.quota_now) or "Reset time not reported")),
			}))
		end
		local heading = {text("cp-label",PROVIDER_NAMES[provider] or provider),text("cp-quota-source","OMP · LOCAL")}
		if logo then table.insert(heading,1,icon(logo,"cp-quota-logo")) end
		local popup = el("div","cp-quota-popover cp-quota-popover-" .. provider_index .. (if low then " cp-popup-low" else ""),{
			el("div","cp-quota-popover-head",heading),
			text("cp-quota-note",if low then "Low quota · less than 10% remains" else "Available quota"),
			el("div","cp-quota-details",details),
			text("cp-quota-footnote","Click to refresh provider limits"),
		})
		local ring = ui.el("button",{class="cp-quota cp-quota-" .. provider_index .. (if low then " cp-quota-low" else ""),attrs={["aria-label"]=(PROVIDER_NAMES[provider] or provider) .. " quota windows" .. (if low then ": low quota" else "")},actions={click="usage"}}, {
			el("div","cp-ring",segments),
		})
		table.insert(quota_nodes,ring)
		table.insert(quota_popovers,popup)
		table.insert(quota_sheets,".switchboard:has(.cp-quota-" .. provider_index .. ":hover) .cp-quota-popover-" .. provider_index .. ", .switchboard:has(.cp-quota-" .. provider_index .. ":focus-visible) .cp-quota-popover-" .. provider_index .. " { display:flex; flex-direction:column; gap:10px; }")
	end

	if show_quotas and data.quota_state then table.insert(quota_nodes,text("cp-quota-state",data.quota_state)) end
	return el("div", "switchboard", {
		el("div", "cp-brand", {el("span","cp-switchboard-mark"), text("cp-brand-name", "Switchboard"),
			el("div","cp-hosts",host_nodes),
			el("button", "cp-tool", nil, "+", "new-workspace")}),
		el("div", "cp-sections", {
			ui.node("split", {
				key="sections", role="switchboard.sections", grow=1, dir="col",
				sizes=section_sizes.read(data.section_sizes),
				min={"6lines","8lines"},
			}, {
				el("div", "cp-projects-section", {
					el("div", "cp-heading", {text("", "Workspaces"), text("cp-count", tostring(#shown))}),
					ui.el("div", {class="cp-projects" .. (if data.workspace_lift then " cp-lift" else "")}, projects),
				}),
				el("div", "cp-agents-section", agents_section),
			}),
		}),
		el("div", "cp-footer", {
			el("div", "cp-launchers", launchers),
			el("div","cp-footer-bottom", {
				ui.button("",{icon="undo",title="Switch to the original Tern sidebar",aria="Switch to the original Tern sidebar",variant="quiet",size="sm",actions={click="restore"}}),
				el("div", "cp-quotas", quota_nodes),
				ui.button("",{icon="sliders",title="Switchboard settings",aria="Switchboard settings",variant="quiet",size="sm",actions={click="settings"}}),
			}),
		}),
		el("div","cp-quota-popovers",quota_popovers),
	},nil,"keep-focus"), table.concat(quota_sheets,"\n")
end

return M
