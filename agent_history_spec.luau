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
-- Tern reuses pane ids: a new agent on a closed entry's pane+cwd must not take over that session's record.
local reuse={{pane=5,name="Old chat",project="p",cwd="/c",session="A",at=1,live=false}}
history.update(reuse,{{pane=5,name="omp",project="p",cwd="/c"}},50,{})
eq(#reuse,2)
local kept_old
for _,entry in reuse do if entry.session=="A" then kept_old=entry end end
assert(kept_old and kept_old.live==false,"closed session A keeps its record")
history.update(reuse,{{pane=5,name="omp",project="p",cwd="/c"}},60,{["5"]={session="B",cwd="/c"}})
eq(kept_old.session,"A")
eq(#history.closed(reuse),1)

local twins={
	{pane=9,name="Resumed chat",project="p",cwd="/c/",at=30,live=true},
	{pane=2,name="Resumed chat",project="p",cwd="/c",session="S",at=5,live=false},
}
eq(history.update(twins,{{pane=9,name="Resumed chat",project="p",cwd="/c/"}},70,{}),true)
eq(#twins,1)
eq(twins[1].session,"S")
eq(twins[1].live,true)
eq(twins[1].pane,9)
eq(#history.closed(twins),0)

-- Pins survive updates and closes, and a pinned closed record leaves the Closed list.
local pins={}
history.update(pins,{{pane=40,name="Keep",project="p",cwd="/p"}},10)
pins[1].pinned=true
pins[1].pinned_at=12
eq(history.update(pins,{{pane=40,name="Keep",project="p",cwd="/p"}},20),false)
eq(pins[1].pinned,true)
eq(pins[1].pinned_at,12)
history.update(pins,{},30)
eq(#history.closed(pins),0)
eq(#history.pinned(pins),1)
eq(pins[1].live,false)
eq(pins[1].pinned_at,12)

-- A pin follows the agent through close and reopen, which merges onto the oldest record.
local resumed={}
history.update(resumed,{{pane=11,name="Resume me",project="p",cwd="/p"}},10,{["11"]={session="R",cwd="/p"}})
resumed[1].pinned=true
resumed[1].pinned_at=15
history.update(resumed,{},20)
eq(#history.pinned(resumed),1)
history.update(resumed,{{pane=12,name="Resume me",project="p",cwd="/p"}},30,{["12"]={session="R",cwd="/p"}})
eq(#resumed,1)
eq(resumed[1].live,true)
eq(resumed[1].pane,12)
eq(resumed[1].pinned,true)
eq(resumed[1].pinned_at,15)
eq(#history.closed(resumed),0)

-- A duplicate session record merges its pin onto the canonical oldest record.
local merged_pin={{pane=1,name="Old pin",project="p",cwd="/c",session="s3",at=10},{pane=2,name="New pin",project="p",cwd="/c",session="s3",at=20,pinned=true,pinned_at=25}}
eq(history.update(merged_pin,{},30),true)
eq(#merged_pin,1)
eq(merged_pin[1].pinned,true)
eq(merged_pin[1].pinned_at,25)

-- Cap trims unpinned records only: a pin older than everything else stays.
local capped_pin={}
local first_batch={}
for i=1,49 do table.insert(first_batch,{pane=i,name="n"..i,project="p",cwd="/c"..i}) end
history.update(capped_pin,first_batch,40)
capped_pin[#capped_pin].pinned=true -- pane 1, the oldest
capped_pin[#capped_pin].pinned_at=45
local second_batch={}
for i=50,60 do table.insert(second_batch,{pane=i,name="n"..i,project="p",cwd="/c"..i}) end
history.update(capped_pin,second_batch,50)
eq(#capped_pin,50)
eq(capped_pin[#capped_pin].pane,1)
eq(capped_pin[#capped_pin].pinned,true)
local pane2_kept=false
for _,entry in capped_pin do if entry.pane==2 then pane2_kept=true end end
eq(pane2_kept,false) -- the oldest unpinned record went instead
-- All pinned: no trimming happens and no infinite loop.
local all_pinned={}
for i=1,51 do table.insert(all_pinned,{pane=i,name="p"..i,project="p",cwd="/q"..i,pinned=true,pinned_at=i,at=i}) end
eq(history.update(all_pinned,{},60),false)
eq(#all_pinned,51)

-- Pinned ordering: pinned_at ascending, at as fallback, pane as the tie-break.
local order={
	{pane=3,name="c",at=30,pinned=true,pinned_at=30},
	{pane=1,name="a",at=20,pinned=true,pinned_at=10},
	{pane=2,name="b",at=40,pinned=true},
	{pane=4,name="d",at=40,pinned=true,pinned_at=40},
}
local sorted=history.pinned(order)
eq(#sorted,4)
eq(sorted[1].pane,1)
eq(sorted[2].pane,3)
eq(sorted[3].pane,2)
eq(sorted[4].pane,4)

-- Placeholder-only closed records survive when pinned.
local pinned_placeholder={}
history.update(pinned_placeholder,{{pane=30,name="zsh",project="p",cwd="/p"}},10)
pinned_placeholder[1].pinned=true
pinned_placeholder[1].pinned_at=11
history.update(pinned_placeholder,{},20)
eq(#pinned_placeholder,1)
eq(pinned_placeholder[1].name,nil)
eq(#history.pinned(pinned_placeholder),1)

-- Simulated clear-history: keep pinned, drop the rest.
local clearing={{pane=20,name="Keep",project="p",cwd="/p",at=1,pinned=true,pinned_at=2},{pane=21,name="Drop",project="p",cwd="/p",at=3}}
local cleared={}
for _,entry in clearing do if entry.pinned then table.insert(cleared,entry) end end
eq(#cleared,1)
eq(cleared[1].pinned,true)

print("agent history checks passed")
return true
