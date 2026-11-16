local flip = require("./tree_flip")
local function eq(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function node(class, id, click)
  return {k="button", p={class=class, key=id, attrs={["aria-pressed"]="false"}, actions=if click then {click=click} else nil}}
end
local function tree(selected)
  return {k="col", c={
    node("cp-card-agent1 cp-agent cp-idle" .. (if selected==1 then " cp-agent-selected" else ""), "agent1", "pane:1"),
    node("cp-card-agent2 cp-agent" .. (if selected==2 then " cp-agent-selected" else ""), "agent2", "pane:2"),
    {k="div", c={
      node("cp-tab" .. (if selected==2 then " cp-selected" else ""), "tab2", "pane:2"),
      node("cp-subagent-card", "child", "subagent:2:child-1"),
    }},
    node("cp-agent cp-closed", "closed", "resume-session:abc"),
  }}
end

-- Moving the highlight off card 2 and onto card 1.
local t = tree(2)
eq(flip.select_card(t, 1), true)
local card1, card2 = t.c[1], t.c[2]
eq(string.find(card1.p.class, "cp-agent-selected", 1, true) ~= nil, true)
eq(string.find(card2.p.class, "cp-agent-selected", 1, true), nil)
eq(card1.p.attrs["aria-pressed"], "true")
eq(card2.p.attrs["aria-pressed"], "false")
-- The workspace tab row and the closed card are untouched by a card-1 pick.
eq(string.find(t.c[3].c[1].p.class, "cp-selected", 1, true), nil)

-- A subagent child selects its parent card and the parent's tab.
local s = tree(1)
eq(flip.select_card(s, 2), true)
eq(string.find(s.c[2].p.class, "cp-agent-selected", 1, true) ~= nil, true)
eq(string.find(s.c[1].p.class, "cp-agent-selected", 1, true), nil)
eq(string.find(s.c[3].c[1].p.class, "cp-selected", 1, true) ~= nil, true)

-- Picking the already-selected card changes nothing.
local same = tree(1)
eq(flip.select_card(same, 1), false)

-- Disclosure still flips open and closed (hyphens are pattern magic, so this regressed once).
local d = {k="button", p={class="cp-subagent-toggle", key="subagents-toggle7", attrs={["aria-expanded"]="false"}}}
eq(flip.toggle_disclosure(d, "subagents-toggle7"), true)
eq(string.find(d.p.class, "cp-subagent-open", 1, true) ~= nil, true)
eq(d.p.attrs["aria-expanded"], "true")
eq(flip.toggle_disclosure(d, "subagents-toggle7"), true)
eq(string.find(d.p.class, "cp-subagent-open", 1, true), nil)
eq(d.p.attrs["aria-expanded"], "false")

eq(flip.select_card(nil, 1), false)
eq(flip.toggle_disclosure(nil, "x"), false)
print("tree flip checks passed")
return true
