local placement=require("./placement")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local root={split="right",ratio=0.2,[1]={pane=7},[2]={split="down",ratio=0.4,[1]={pane=8},[2]={pane=9}}}
eq(placement.first(root,7),8)
eq(placement.share(root,7),0.2)
eq(placement.share(root,9),nil)
eq(placement.share({split="down",ratio=0.4,[1]=root,[2]={pane=10}},7),0.2)
local calls=0
local cx={session={layout=function() return {root=root} end},layout={resize=function(_,pane,dir,cells)
 eq(pane,7);eq(dir,"right");calls+=1;root.ratio=math.clamp(root.ratio+cells*0.004,0.1,0.9);return true
end}}
placement.size(cx,1,7,0.28)
assert(math.abs(root.ratio-0.28)<0.000001)
local before=calls
placement.size(cx,1,7,0.28)
eq(calls,before)
local nearRoot={split="right",ratio=0.2005,[1]={pane=7},[2]={pane=8}}
local nearCalls=0
local nearCx={session={layout=function() return {root=nearRoot} end},layout={resize=function()
 nearCalls+=1
end}}
placement.size(nearCx,1,7,0.2)
eq(nearCalls,0)
eq(nearRoot.ratio,0.2005)
print("placement specs passed")

local snapshot={}
local restored=false
local failCx={session={layout=function() return {root={pane=8}} end},layout={snapshot=function() return snapshot end,
 park=function() return true end,
 move=function() return false end,
 restore=function(_,value) eq(value,snapshot);restored=true;return true end}}
local ok,err=pcall(placement.wrap,failCx,1,7,{pane=8},0.2)
eq(ok,false);eq(restored,true)
assert(string.find(tostring(err),"layout restored",1,true))
print("layout rollback check passed")

local live={[8]=true,[9]=true}
local mixed={split="right",ratio=0.2,[1]={pane=7},[2]={split="right",ratio=0.5,[1]={pane=8},[2]={pane=9}}}
local retainedCx={session={layout=function() return {root=mixed} end},layout={
 snapshot=function() return {} end,
 park=function(_,pane) assert(pane~=8,"First content pane must stay live");live[pane]=nil;assert(live[8]);return true end,
 unpark=function(_,pane) assert(live[8]);live[pane]=true;return true end,
 move=function() assert(live[8],"Sidebar must never be alone");return true end,
 resize=function() assert(live[8]);return true end,
 restore=function() return true end,
 focus=function() error("Wrap must not focus the sidebar") end,
}}
placement.wrap(retainedCx,1,7,{split="right",ratio=0.5,[1]={pane=8},[2]={pane=9}},0.2)
eq(live[8],true);eq(live[9],true)
print("retained content regression check passed")
return true
