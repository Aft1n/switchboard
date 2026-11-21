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

-- Stylesheet: 36 slots, 18 token hue recipes x 2 tones, theme tokens only, no red.
local sheet=pc.css()
local selectors,duplicates={},{}
for slot in string.gmatch(sheet,"%.cp%-color%-(%d+) {") do
	eq(duplicates[slot],nil)
	duplicates[slot]=true
	selectors[#selectors+1]=tonumber(slot)
end
eq(#selectors,36)
for slot=1,36 do eq(duplicates[tostring(slot)],true) end
local lines={}
for line in string.gmatch(sheet,"[^\n]+") do table.insert(lines,line) end
eq(#lines,36)
local FAMILIES={"--ink-pen","--ansi3","--ansi2","--ansi6","--ansi4","--ansi5"}
local family_index={}
for i,token in ipairs(FAMILIES) do family_index[token]=i end
for _,red in ipairs({"--ansi1","--ansi9","--bad"}) do
	eq(string.find(sheet,red,1,true),nil) -- red reserved for urgent/needs-input
end
local counts={}
for _,token in ipairs(FAMILIES) do counts[token]=0 end
local recipes={}
for slot,line in ipairs(lines) do
	eq(string.find(line,if slot<=18 then "50%, var(--t2)" else "60%, var(--ink)",1,true)~=nil,true)
	local tokens={}
	for token in string.gmatch(line,"var%((%-%-[%w%-]+)") do
		if token~="--t2" and token~="--ink" and token~="--accent" then table.insert(tokens,token) end
	end
	eq(#tokens>=1,true)
	eq(family_index[tokens[1]]~=nil,true)
	counts[tokens[1]]+=1
	if #tokens==2 then
		-- Mixes only go into the next family, never back onto a repeated hue.
		eq(family_index[tokens[2]],family_index[tokens[1]]%#FAMILIES+1)
	end
	local tone=if slot<=18 then 1 else 2
	local shares={}
	for share in string.gmatch(line,"%d+%%") do shares[#shares+1]=share end
	local key=tone..":"..table.concat(tokens,"|").."@"..table.concat(shares,",")
	eq(recipes[key],nil)
	recipes[key]=true
end
for _,token in ipairs(FAMILIES) do eq(counts[token],6) end
eq(lines[1], ".cp-color-1 { color: color-mix(in srgb, var(--ink-pen, var(--accent)) 50%, var(--t2)) !important; }")
eq(lines[19], ".cp-color-19 { color: color-mix(in srgb, var(--ink-pen, var(--accent)) 60%, var(--ink)) !important; }")
eq(lines[36], ".cp-color-36 { color: color-mix(in srgb, color-mix(in srgb, var(--ansi4, var(--accent)) 68%, var(--ansi5, var(--accent))) 60%, var(--ink)) !important; }")

eq(pc.class(4),"cp-color-4")
eq(pc.class(36),"cp-color-36")
eq(pc.class(nil),nil)
print("project color checks passed")
return true
