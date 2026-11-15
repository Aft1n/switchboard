local recency=require("./workspace_recency")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local HOUR=60*60*1000
local now=100*HOUR
local function names(list) local out={} for _,p in list do table.insert(out,p.name) end return table.concat(out,",") end
local projects={{id=1,name="a"},{id=2,name="b"},{id=3,name="c"},{id=4,name="d"}}
recency.sort(projects,{},now)
eq(names(projects),"a,b,c,d") -- no stamps: Tern's order
recency.sort(projects,{["3"]=now-HOUR,["2"]=now-2*HOUR,["4"]=now-25*HOUR},now)
eq(names(projects),"c,b,a,d") -- newest first, then the rest in their old order; 25 h is stale
local fresh={{id=1,name="a"},{id=2,name="b"},{id=3,name="c"},{id=4,name="d"}}
recency.sort(fresh,{["1"]=now-HOUR,["2"]=now-HOUR},now)
eq(names(fresh),"a,b,c,d") -- equal stamps keep their order
print("workspace recency checks passed")
return true
