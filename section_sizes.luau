-- One shared Workspaces/Agents split; only completed user drags update it.
local M = {}
local function finite(v)
 return type(v)=="number" and v==v and v~=math.huge and v~=-math.huge
end
function M.normalize(value)
 if type(value)~="table" or #value~=2 then return nil end
 local a,b=value[1],value[2]
 if not finite(a) or not finite(b) or a<=0 or b<=0 or not finite(a+b) then return nil end
 return {a/(a+b),b/(a+b)}
end
function M.read(value)
 return M.normalize(value) or {0.42,0.58}
end
function M.same(a,b)
 return type(a)=="table" and type(b)=="table" and finite(a[1]) and finite(a[2])
  and finite(b[1]) and finite(b[2]) and math.abs(a[1]-b[1])<0.001 and math.abs(a[2]-b[2])<0.001
end
return M
