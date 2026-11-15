local pc=require("./project_colors")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
eq(pc.TOTAL,36)

-- 36 slots: 36 distinct names all differ, then the store is full.
local store={next=1,colors={}}
local seen={}
for i=1,36 do
	local color=pc.ensure(store,"p"..i)
	eq(color,i)
	eq(seen[color],nil)
	seen[color]=true
end
eq(pc.ensure(store,"overflow"),nil)
eq(pc.ensure(store,nil),nil)
eq(pc.ensure(store,""),nil)

-- Ten-plus names must never collide.
local many={next=1,colors={}}
local many_seen={}
for i=1,14 do
	local color=pc.ensure(many,"project"..i)
	eq(many_seen[color],nil)
	many_seen[color]=true
end
eq(many.next,15)

-- Legacy duplicates and invalid slots: first valid occurrence in sorted-name order
-- stays, the rest take the lowest free slots; a second pass changes nothing.
local legacy={next=9,colors={alpha=3,beta=3,gamma=3,delta=99,epsilon=5}}
eq(pc.rebalance(legacy),true)
eq(legacy.colors.alpha,3) -- first valid claim on slot 3
eq(legacy.colors.epsilon,5) -- unique valid slot untouched
eq(legacy.colors.beta,1)
eq(legacy.colors.delta,2)
eq(legacy.colors.gamma,4)
eq(legacy.next,6)
local unique={}
for _,slot in pairs(legacy.colors) do eq(unique[slot],nil); unique[slot]=true end
eq(pc.rebalance(legacy),false)
eq(pc.rebalance({colors={}}),false)
eq(pc.rebalance({colors={a=1}}),false)
eq(pc.rebalance(nil),false)
eq(pc.rebalance({colors="nope"}),false)

-- Ensure skips occupied slots and wraps; malformed next falls back to slot 1.
local skip={next=1,colors={a=1,b=2}}
eq(pc.ensure(skip,"c"),3)
eq(pc.ensure(skip,"d"),4)
eq(pc.ensure({next="nope",colors={["x"]=9}},"recover"),1)
eq(pc.ensure({colors={a=1,b=2}},"fallback"),3)
local wrap={next=36,colors={a=1,b=2}}
eq(pc.ensure(wrap,"w"),36)

-- Stylesheet: 36 distinct slots, 17 red-free bases, 19 cool-led mixes.
local sheet=pc.css()
local selectors,duplicates={},{}
for slot in string.gmatch(sheet,"%.cp%-color%-(%d+) {") do
	eq(duplicates[slot],nil)
	duplicates[slot]=true
	selectors[#selectors+1]=tonumber(slot)
end
eq(#selectors,36)
for slot=1,36 do eq(duplicates[tostring(slot)],true) end
eq(string.find(sheet,"--c",1,true),nil) -- no invented --c1..6 variables
local lines={}
for line in string.gmatch(sheet,"[^\n]+") do table.insert(lines,line) end
eq(#lines,36)
local bases,pairs=0,0
for _,line in ipairs(lines) do
	local count=0
	for _ in string.gmatch(line,"color%-mix%(") do count=count+1 end
	if count==1 then bases=bases+1 elseif count==2 then pairs=pairs+1 end
end
eq(bases,17) -- direct token smoothed 40% with --t2
eq(pairs,19) -- pair color smoothed 40% with --t2
local direct={}
for i=1,17 do direct[i]=string.match(lines[i],"var%((%-%-[%w%-]+),") end
local expected={"--ansi2","--ansi3","--ansi4","--ansi5","--ansi6","--ansi10","--ansi11","--ansi12","--ansi13","--ansi14","--a1","--a2","--accent-ink","--ok","--warn","--live","--ink-pen"}
for i,token in ipairs(expected) do eq(direct[i],token) end
eq(direct[1],"--ansi2"); eq(direct[6],"--ansi10"); eq(direct[12],"--a2"); eq(direct[17],"--ink-pen")
local present={}
for i=1,17 do present[direct[i]]=true end
eq(present["--ansi1"],nil) -- red reserved for urgent/needs-input
eq(present["--ansi9"],nil)
eq(present["--bad"],nil)
for _,token in ipairs({"--ansi1","--ansi9","--bad"}) do
	eq(string.find(sheet,"var("..token..",",1,true),nil)
end
eq(lines[1], ".cp-color-1 { color: color-mix(in srgb, var(--ansi2, var(--accent)) 40%, var(--t2)) !important; }")
eq(lines[6], ".cp-color-6 { color: color-mix(in srgb, var(--ansi10, var(--accent)) 40%, var(--t2)) !important; }")
eq(lines[18], ".cp-color-18 { color: color-mix(in srgb, color-mix(in srgb, var(--ansi4, var(--accent)) 65%, var(--ansi10, var(--accent))) 40%, var(--t2)) !important; }")
eq(lines[36], ".cp-color-36 { color: color-mix(in srgb, color-mix(in srgb, var(--a1, var(--accent)) 65%, var(--a2, var(--accent))) 40%, var(--t2)) !important; }")
local cool={["--ansi4"]=true,["--ansi6"]=true,["--ansi2"]=true,["--a2"]=true,["--a1"]=true,["--accent-ink"]=true,["--ok"]=true}
local pair_seen={}
for slot=18,36 do
	local first=string.match(lines[slot],"var%((%-%-[%w%-]+),")
	local second=string.match(lines[slot],"65%%, var%((%-%-[%w%-]+),")
	eq(cool[first],true)
	assert(second, "missing mix second operand")
	eq(pair_seen[first .. "|" .. second],nil)
	pair_seen[first .. "|" .. second]=true
end

eq(pc.class(4),"cp-color-4")
eq(pc.class(36),"cp-color-36")
eq(pc.class(nil),nil)
print("project color checks passed")
return true
