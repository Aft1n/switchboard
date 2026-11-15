local keyboard=require("./keyboard")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function eq_list(actual,expected)
 eq(#actual,#expected)
 for i,value in expected do eq(actual[i],value) end
end

local remote=4521191813414916
local agents={
 {pane=17,state="working"},
 {pane=99,state="exited"},
 {pane=remote,state="waiting_input"},
 {pane=33,state="idle"},
}
eq_list(keyboard.panes(agents),{17,remote,33})
eq(keyboard.next(agents,17),remote)
eq(keyboard.next(agents,remote),33)
eq(keyboard.next(agents,33),17)
eq(keyboard.previous(agents,17),33)
eq(keyboard.previous(agents,33),remote)
eq(keyboard.previous(agents,remote),17)

-- From a non-agent pane, forward starts at the first card and backward at the last.
eq(keyboard.next(agents,500),17)
eq(keyboard.previous(agents,500),33)
eq(keyboard.next(agents,nil),17)
eq(keyboard.previous(agents,nil),33)

eq(keyboard.at(agents,1),17)
eq(keyboard.at(agents,2),remote)
eq(keyboard.at(agents,3),33)
eq(keyboard.at(agents,9),nil)
eq(keyboard.at(agents,0),nil)
eq(keyboard.at(agents,1.5),nil)
eq(keyboard.at(agents,"1"),nil)
local nine={}
for i=1,9 do table.insert(nine,{pane=i,state="idle"}) end
eq(keyboard.at(nine,1),1)
eq(keyboard.at(nine,9),9)
eq(keyboard.at(nine,10),nil)

eq_list(keyboard.panes(nil),{})
eq(keyboard.next({},17),nil)
eq(keyboard.previous({},17),nil)
eq(keyboard.at({},1),nil)

-- Navigation does not sort or mutate the rendered agent rows.
eq(agents[1].pane,17)
eq(agents[2].pane,99)
eq(agents[3].pane,remote)
eq(agents[4].pane,33)
print("keyboard navigation checks passed")

local chords=keyboard.chords({["alt+j"]={"plugin.switchboard.next-agent"},["alt+k"]={"plugin.switchboard.previous-agent"},["ctrl+alt+j"]={"plugin.switchboard.next-agent"}},"plugin.switchboard.next-agent")
assert(#chords==2 and chords[1]=="alt+j" and chords[2]=="ctrl+alt+j")
return true
