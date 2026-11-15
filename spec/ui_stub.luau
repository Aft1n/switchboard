--!strict
-- Stand-in for `tern.ui` so view builders can be unit-tested without Tern.
-- Builders return the plain node tables the real UI consumes; no Tern globals, no io.

local M: any = {}

-- Tern's builders validate their arguments and raise
-- `tern.ui.<builder>: <argument>: <problem>`. The stub does the same, so a spec
-- catches the mistakes the real UI would crash on. The two that bite:
--   * a node where spans belong (a badge in a card head)
--   * a nil hole in a children list
local function is_node(v: any): boolean
	return type(v) == "table" and type(v.k) == "string"
end

local function check_spans(where: string, spans: any): ()
	if spans == nil or type(spans) == "string" then
		return
	end
	if is_node(spans) then
		error(where .. ": a node is not a span", 3)
	end
	if type(spans) ~= "table" then
		error(where .. ": expected text", 3)
	end
	if spans.t ~= nil then
		return
	end
	for i = 1, #spans do
		local s = spans[i]
		if type(s) ~= "string" and type(s) ~= "table" then
			error(where .. ": span " .. i .. " is not text", 3)
		end
		if is_node(s) then
			error(where .. ": a node is not a span (index " .. i .. ")", 3)
		end
	end
end

local function check_children(where: string, children: any): ()
	if children == nil then
		return
	end
	if type(children) ~= "table" then
		error(where .. ": expected a list of nodes", 3)
	end
	local seen = 0
	for _ in pairs(children) do
		seen += 1
	end
	if seen ~= #children then
		error(where .. ": a nil hole in the children", 3)
	end
	for i = 1, #children do
		if not is_node(children[i]) then
			error(where .. ": child " .. i .. " is not a node", 3)
		end
	end
end

-- Walks a tree the way Tern would, so a spec can assert a whole view is valid.
function M.validate(view: any): ()
	if view == nil then
		return
	end
	if type(view) == "table" and view.k == nil then
		for _, region in pairs(view) do
			M.validate(region)
		end
		return
	end
	if not is_node(view) then
		error("not a node", 3)
	end
	local kind = view.k
	local p = view.p or {}
	if kind == "card" or kind == "section" then
		check_spans("tern.ui." .. kind, p.head)
	elseif kind == "text" then
		check_spans("tern.ui.text", p.spans)
	elseif kind == "rule" and p.label ~= nil then
		check_spans("tern.ui.rule", p.label)
	elseif kind == "kv" then
		for i, item in ipairs(p.items or {}) do
			if type(item) ~= "table" then
				error("tern.ui.kv: item " .. i .. " is not a pair", 3)
			end
			check_spans("tern.ui.kv.key", item.k)
			check_spans("tern.ui.kv.value", item.v)
		end
	elseif kind == "list" then
		for i, item in ipairs(view.c or {}) do
			local ip = item.p or {}
			if ip.label == nil then
				error("tern.ui.list: item " .. i .. " has no label", 3)
			end
			for _, f in { "label", "detail", "value" } do
				check_spans("tern.ui.list." .. f, ip[f])
			end
		end
	end
	check_children("tern.ui." .. kind, view.c)
	for _, child in ipairs(view.c or {}) do
		M.validate(child)
	end
end

-- {k=...} plus p/c only when non-empty.
local function node(kind: string, p: any, c: any): any
	check_children("tern.ui." .. kind, c)
	local out: any = { k = kind }
	if p and next(p) ~= nil then
		out.p = p
	end
	if c and #c > 0 then
		out.c = c
	end
	return out
end

local function span(t: string, s: string?): any
	local out: any = { t = t }
	if s and s ~= "" then
		out.s = s
	end
	return out
end

local function text(spans: any): any
	check_spans("tern.ui.text", spans)
	return node("text", { spans = spans }, nil)
end

local function col(children: any): any
	return node("col", { gap = "sm" }, children)
end

local function lines(children: any): any
	return node("col", { gap = "none" }, children)
end

local function row(children: any): any
	return node("row", { gap = "sm" }, children)
end

local function card(head: any, children: any): any
	check_spans("tern.ui.card.head", head)
	return node("card", { head = head }, children)
end

local function section(head: any, children: any): any
	check_spans("tern.ui.section.head", head)
	return node("section", { head = head }, children)
end

local function rule(label: string?): any
	if label == nil then
		return node("rule", nil, nil)
	end
	return node("rule", { label = label }, nil)
end

local function badge(t: string, tone: string?): any
	if type(t) ~= "string" then
		error("tern.ui.badge: text: expected a string", 3)
	end
	return node("badge", { text = t, tone = tone }, nil)
end

-- items: { {keySpans, valueSpans}, ... }
local function kv(items: any): any
	if type(items) ~= "table" then
		error("tern.ui.kv: items: expected pairs", 3)
	end
	local out = {}
	for i, item in ipairs(items) do
		if type(item) ~= "table" or item[1] == nil then
			error("tern.ui.kv: item " .. i .. ": expected a key and a value", 3)
		end
		check_spans("tern.ui.kv.key", item[1])
		check_spans("tern.ui.kv.value", item[2])
		out[i] = { k = item[1], v = item[2] }
	end
	return node("kv", { items = out }, nil)
end

local function meter(value: any, label: any): any
	return node("meter", { value = value, label = label }, nil)
end

local function progress(value: any, label: any): any
	return node("progress", { value = value, label = label }, nil)
end

-- Native bars and spark expect positional { label: string, value: number } pairs.
local function to_series(kind: string, series: any): any
	if type(series) ~= "table" then
		error("tern.ui." .. kind .. ": series: expected a table, got " .. type(series), 3)
	end
	local out = {}
	for i, item in ipairs(series) do
		if type(item) ~= "table" then
			error("tern.ui." .. kind .. ": series[" .. i .. "]: expected a label/value pair, got " .. type(item), 3)
		end
		if type(item[1]) ~= "string" then
			local got = if item[1] == nil then "nil" else type(item[1])
			error("tern.ui." .. kind .. ": series[" .. i .. "][1]: expected a string, got " .. got, 3)
		end
		if type(item[2]) ~= "number" then
			local got = if item[2] == nil then "nil" else type(item[2])
			error("tern.ui." .. kind .. ": series[" .. i .. "][2]: expected a number, got " .. got, 3)
		end
		out[i] = { label = item[1], value = item[2] }
	end
	return out
end

local function chart(kind: string, series: any): any
	return node("chart", { kind = kind, series = to_series(kind, series) }, nil)
end

local function bars(series: any): any
	return chart("bars", series)
end

local function spark(series: any): any
	return chart("spark", series)
end

local function table_builder(cols: any, rows: any): any
	local out = {}
	for i, row_cells in ipairs(rows) do
		out[i] = { id = "r" .. tostring(i - 1), cells = row_cells }
	end
	return node("table", { cols = cols, rows = out }, nil)
end

-- items: { { label=, detail=, value=, icon=, tone= }, ... }; absent fields are dropped.
local ITEM_FIELDS = { "label", "detail", "value", "icon", "tone" }

local function list(items: any): any
	local out = {}
	for i, item in ipairs(items) do
		local p: any = {}
		for _, f in ITEM_FIELDS do
			if item[f] ~= nil then
				p[f] = item[f]
			end
		end
		out[i] = node("item", p, nil)
	end
	return node("list", nil, out)
end

-- nodes: { { label=, icon=, open=, children={...} }, ... }; ids are depth-first t0, t1, ...
local function tree_nodes(list_in: any, counter: { n: number }): any
	local out = {}
	for i, n in ipairs(list_in) do
		local out_node: any = { id = "t" .. tostring(counter.n) }
		counter.n += 1
		if n.label ~= nil then
			out_node.label = n.label
		end
		if n.icon ~= nil then
			out_node.icon = n.icon
		end
		if n.open ~= nil then
			out_node.open = n.open
		end
		local kids = n.children or n.c
		if kids and #kids > 0 then
			out_node.c = tree_nodes(kids, counter)
		end
		out[i] = out_node
	end
	return out
end

local function tree(nodes: any): any
	return node("tree", { nodes = tree_nodes(nodes, { n = 0 }) }, nil)
end

local function code(t: string, lang: string?, start: number?): any
	local p: any = { text = t }
	if lang and lang ~= "" then
		p.lang = lang
	end
	if start ~= nil then
		p.start = start
	end
	return node("code", p, nil)
end

local function diff(t: string, path: string?): any
	local p: any = { text = t }
	if path and path ~= "" then
		p.path = path
	end
	return node("diff", p, nil)
end

local function md(t: string): any
	return node("md", { text = t }, nil)
end

local function ansi(t: string): any
	return node("ansi", { text = t }, nil)
end

local function el(tag: string, props: any, children: any): any
	local p: any = { tag = tag }
	for k, v in props or {} do
		p[k] = v
	end
	return node("el", p, children)
end

local function meter_cell(value: any, thresholds: any): any
	local m: any = { value = value }
	if thresholds ~= nil then
		m.thresholds = thresholds
	end
	return { meter = m }
end

local function meter_parts_cell(parts: any): any
	return { meter = { parts = parts } }
end

local function overflow(hidden: any): any
	return text({ span("… " .. tostring(hidden) .. " more", "muted") })
end

-- Documents the `with()` pattern from the docs: merges props into node.p in place.
local function with_props(n: any, props: any): any
	n.p = n.p or {}
	for k, v in props or {} do
		n.p[k] = v
	end
	return n
end

local function text_of(v: any): string
	if type(v) == "string" then
		return v
	end
	if type(v) == "number" then
		return tostring(v)
	end
	return ""
end

local function spans_text(spans: any): string
	local t = type(spans)
	if t == "string" or t == "number" then
		return tostring(spans)
	end
	if t ~= "table" then
		return ""
	end
	if spans.t ~= nil then
		return text_of(spans.t)
	end
	local out = {}
	for _, sp in ipairs(spans) do
		if type(sp) == "string" then
			out[#out + 1] = sp
		else
			out[#out + 1] = text_of(sp.t)
		end
	end
	return table.concat(out)
end

local function flatten(n: any, out: { string }): ()
	if type(n) == "string" then
		table.insert(out, n)
		return
	end
	if type(n) ~= "table" then
		return
	end
	local k = n.k
	local p = n.p or {}
	if k == nil then
		-- tree node: {id=..., label=..., c=...}
		if n.label ~= nil then
			table.insert(out, text_of(n.label))
		end
		for _, child in ipairs(n.c or {}) do
			flatten(child, out)
		end
		return
	end
	if k == "text" then
		table.insert(out, spans_text(p.spans))
	elseif k == "code" or k == "diff" or k == "md" or k == "ansi" or k == "badge" then
		table.insert(out, text_of(p.text))
	elseif k == "rule" then
		if p.label ~= nil then
			table.insert(out, spans_text(p.label))
		end
	elseif k == "kv" then
		for _, item in ipairs(p.items or {}) do
			table.insert(out, spans_text(item.k))
			table.insert(out, spans_text(item.v))
		end
	elseif k == "list" then
		for _, item in ipairs(n.c or {}) do
			local ip = item.p or {}
			for _, f in { "label", "detail", "value" } do
				if ip[f] ~= nil then
					table.insert(out, spans_text(ip[f]))
				end
			end
		end
	elseif k == "item" then
		for _, f in { "label", "detail", "value" } do
			if p[f] ~= nil then
				table.insert(out, spans_text(p[f]))
			end
		end
	elseif k == "table" then
		-- Cells arrive as Tern's positional arrays or keyed by column id; both
		-- shapes render in the order the columns are declared.
		for _, row_node in ipairs(p.rows or {}) do
			for i, col_def in ipairs(p.cols or {}) do
				local id = (type(col_def) == "table" and (col_def.id or col_def.k)) or col_def
				local cells = row_node.cells
				local cell = if type(cells) == "table" then (cells[i] or cells[id]) else nil
				if type(cell) == "table" then
					if cell.meter ~= nil then
						-- a meter cell draws its bar; it carries no text
					elseif cell.k ~= nil or cell.label ~= nil or cell.c ~= nil then
						flatten(cell, out)
					else
						table.insert(out, spans_text(cell))
					end
				elseif cell ~= nil then
					table.insert(out, text_of(cell))
				end
			end
		end
	elseif k == "tree" then
		for _, tree_node in ipairs(p.nodes or {}) do
			flatten(tree_node, out)
		end
	else
		if p.head ~= nil then
			table.insert(out, spans_text(p.head))
		end
		for _, child in ipairs(n.c or {}) do
			flatten(child, out)
		end
	end
end

-- Depth-first text of a node tree, one line per text blob (multi-line text keeps its own newlines).
local function render(n: any): string
	local out: { string } = {}
	flatten(n, out)
	return table.concat(out, "\n")
end

local function find(n: any, pred: (any) -> boolean): any?
	if type(n) ~= "table" then
		return nil
	end
	if pred(n) then
		return n
	end
	for _, child in ipairs(n.c or {}) do
		local hit = find(child, pred)
		if hit then
			return hit
		end
	end
	-- tree nodes live under p.nodes
	for _, tree_node in ipairs((n.p and n.p.nodes) or {}) do
		local hit = find(tree_node, pred)
		if hit then
			return hit
		end
	end
	return nil
end

M.ui = {
	span = span,
	text = text,
	col = col,
	lines = lines,
	row = row,
	card = card,
	section = section,
	rule = rule,
	badge = badge,
	kv = kv,
	meter = meter,
	progress = progress,
	bars = bars,
	spark = spark,
	table = table_builder,
	list = list,
	tree = tree,
	code = code,
	diff = diff,
	md = md,
	ansi = ansi,
	node = node,
	el = el,
	meter_cell = meter_cell,
	meter_parts_cell = meter_parts_cell,
	overflow = overflow,
}

M.render = render
M.find = find
M.with_props = with_props

return M
