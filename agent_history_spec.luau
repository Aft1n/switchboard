local history=require("./agent_history")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end

-- First sight sets the order and `at`; later updates refresh labels only.
local list={}
eq(history.update(list,{{pane=1,name="a",project="p",cwd="/x"},{pane=2,name="b",project="p",cwd="/y"}},10),true)
eq(#list,2)
eq(list[1].pane,2) -- newest first
eq(history.update(list,{{pane=1,name="a",project="p",cwd="/x"},{pane=2,name="b",project="p",cwd="/y"}},20),false)
eq(list[1].at,10) -- first sight is kept
eq(history.update(list,{{pane=2,name="b renamed",project="p",cwd="/y"}},30),true)
eq(list[1].name,"b renamed")

-- Closed uses update's live flag: pane 1 is gone, pane 2 is live.
local closed=history.closed(list)
eq(#closed,1)
eq(closed[1].pane,1)
eq(closed[1].cwd,"/x")
eq(#history.closed(list,{{pane=1},{pane=2}}),1) -- pane membership alone is not identity

-- A different agent reusing a pane with a new cwd must not overwrite the old record.
local reuse={}
history.update(reuse,{{pane=7,name="Old agent",project="d",cwd="/a"}},10)
history.update(reuse,{{pane=7,name="New agent",project="d",cwd="/b"}},20)
eq(#reuse,2)
eq(reuse[1].pane,7)
eq(reuse[1].name,"New agent")
eq(reuse[2].name,"Old agent")
eq(reuse[2].at,10)
eq(reuse[2].live,false)
closed=history.closed(reuse)
eq(#closed,1)
eq(closed[1].cwd,"/a")

-- A discovered session keeps one entry across a pane change and its first sight.
local moved={}
history.update(moved,{{pane=3,name="Runner",project="p",cwd="/r"}},10,{["3"]={session="S1",cwd="/r"}})
eq(moved[1].session,"S1")
history.update(moved,{{pane=9,name="Runner",project="p",cwd="/r"}},20,{["9"]={session="S1",cwd="/r"}})
eq(#moved,1)
eq(moved[1].pane,9)
eq(moved[1].at,10)

-- Duplicates of one session merge into the oldest record, updated from the live agent.
local dup={{pane=1,name="Dup live",project="p",cwd="/p",at=10,session="S"},{pane=2,name="Dup old",project="p",cwd="/p",at=5,session="S"}}
history.update(dup,{{pane=2,name="Dup renamed",project="p",cwd="/p"}},20,{["2"]={session="S",cwd="/p"}})
eq(#dup,1)
eq(dup[1].at,5)
eq(dup[1].name,"Dup renamed")

-- A stale inspect mapping for a reused pane must not attach the old session.
local stale={}
history.update(stale,{{pane=7,name="Old agent",project="p",cwd="/a"}},10,{["7"]={session="S",cwd="/a"}})
eq(stale[1].session,"S")
history.update(stale,{{pane=7,name="New agent",project="p",cwd="/b"}},20,{["7"]={session="S",cwd="/a"}})
eq(#stale,2)
eq(stale[1].pane,7)
eq(stale[1].session,nil) -- mapping cwd did not match the new agent
eq(stale[2].name,"Old agent")
eq(stale[2].session,"S")
eq(#history.closed(stale),1)

-- OMP /new swaps the session inside the same pane: the old session becomes closed history.
local swapped={}
history.update(swapped,{{pane=7,name="Chat",project="p",cwd="/p"}},10,{["7"]={session="A",cwd="/p"}})
history.update(swapped,{{pane=7,name="Chat",project="p",cwd="/p"}},20,{["7"]={session="B",cwd="/p"}})
eq(#swapped,2)
eq(swapped[1].session,"B")
eq(swapped[2].session,"A")
eq(swapped[2].live,false)
eq(history.closed(swapped)[1].session,"A")

-- The host display name is metadata, kept for reopening: recorded when the live
-- agent carries a host, preserved when a later update carries none, and only
-- rewritten when it actually changes.
local hosted={}
history.update(hosted,{{pane=4,name="Remote runner",project="p",cwd="/r",host={id="h1",name="build box"}}},10)
eq(hosted[1].host,"build box")
eq(history.update(hosted,{{pane=4,name="Remote runner",project="p",cwd="/r"}},11),false)
eq(hosted[1].host,"build box")
eq(history.update(hosted,{{pane=4,name="Remote runner",project="p",cwd="/r",host={id="h2",name="edge box"}}},12),true)
eq(hosted[1].host,"edge box")

-- Placeholder labels (paths, prompts, shell names) are never stored; live agents
-- inherit the last real name instead.
local names={}
history.update(names,{{pane=6,name="Real agent",project="p",cwd="/p"}},10)
local agent={pane=6,name="aftin@host:~/p",project="p",cwd="/p"}
history.update(names,{agent},20)
eq(agent.name,"Real agent")
eq(names[1].name,"Real agent")
local placeholders={}
history.update(placeholders,{{pane=5,name="/Users/x/repo",project="repo",cwd="/Users/x/repo"}},10)
eq(placeholders[1].name,nil)
history.update(placeholders,{{pane=5,name="zsh",project="repo",cwd="/Users/x/repo"}},20)
eq(placeholders[1].name,nil)
for _,placeholder in {{name="omp"},{name="/tmp/x"},{name="~/Code"},{name="cmd"},{name="'quoted path'"},{name="line\nbreak"},{name="repo"}} do
	eq(history.is_placeholder(placeholder.name,"/Users/x/repo","repo"),true)
end
eq(history.is_placeholder("Fix auth","/Users/x/repo","repo"),false)

-- Placeholder-only closed records are dropped.
local drop={}
history.update(drop,{{pane=8,name="zsh",project="p",cwd="/p"}},10)
eq(#drop,1)
history.update(drop,{},20)
eq(#drop,0)
eq(#history.closed(drop),0)

-- Cap.
local capped={}
local batch={}
for i=1,60 do table.insert(batch,{pane=i,name="n"..i,project="p",cwd="/c"..i}) end
history.update(capped,batch,40)
eq(#capped,50)
eq(capped[1].pane,60)
eq(capped[50].pane,11)
-- A session recorded twice while closed merges to its oldest sight.
local twice={{pane=2,name="New",project="p",cwd="/c",session="s1",at=20},{pane=1,name="Old",project="p",cwd="/c",session="s1",at=10},{pane=3,name="Other",project="p",cwd="/d",session="s2",at=15}}
eq(history.update(twice,{},30),true)
eq(#twice,2)
eq(twice[1].at==10 or twice[2].at==10,true)
eq(#history.closed(twice),2)
print("agent history checks passed")
return true
