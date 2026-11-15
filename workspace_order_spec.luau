local order=require("./workspace_order")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function names(list) local out={} for _,p in list do table.insert(out,p.name) end return table.concat(out,",") end
local function ids(list) return table.concat(list,",") end
local projects={{id=1,name="a"},{id=2,name="b"},{id=3,name="c"},{id=4,name="d"}}
order.sort(projects,{})
eq(names(projects),"a,b,c,d") -- no drags yet: Tern's order
order.sort(projects,{"3","2","1"})
eq(names(projects),"c,b,a,d") -- saved first, new workspace appended
local fresh={{id=1,name="a"},{id=2,name="b"},{id=3,name="c"},{id=4,name="d"}}
order.sort(fresh,{"4","2"})
eq(names(fresh),"d,b,a,c") -- unlisted keep their mutual order
local list=order.ids(fresh)
eq(ids(list),"4,2,1,3")
eq(ids(order.move(order.ids(fresh),"3","2")),"4,3,2,1") -- up: above the row clicked
local down=order.ids(fresh)
eq(ids(order.move(down,"2","3")),"4,1,2,3") -- down past the next row
eq(ids(order.move(order.ids(fresh),"4","1")),"2,4,1,3") -- down: above the row clicked
eq(order.move(list,"2","2"),nil) -- dropped on itself
eq(order.move(list,"9","1"),nil) -- gone workspace
print("workspace order checks passed")
return true
