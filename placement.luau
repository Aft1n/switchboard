local M={}

function M.first(node,skip)
 if not node then return nil end
 if node.pane then return if node.pane~=skip then node.pane else nil end
 return M.first(node[1],skip) or M.first(node[2],skip)
end

local function contains(node,pane)
 if not node then return false end
 if node.pane then return node.pane==pane end
 return contains(node[1],pane) or contains(node[2],pane)
end

function M.share(node,pane)
 if not node then return nil end
 if node.pane then return if node.pane==pane then 1 else nil end
 if node.split=="right" then
  local part=M.share(node[1],pane)
  return part and part*(node.ratio or 0.5)
 end
 return M.share(if contains(node[1],pane) then node[1] else node[2],pane)
end

-- Tern's cell size differs between hidden and shown tabs. Measure the change
-- in native ratio after each synchronous step, rather than starting a later
-- process or timer that visibly resizes the pane after navigation.
function M.size(cx,tab,pane,want)
 local shape=cx.session:layout(tab)
 local current=shape and M.share(shape.root,pane)
 if not current then return end
 local cells=(want-current)*180
 for _=1,8 do
  if math.abs(want-current)<0.001 or math.abs(cells)<0.000001 then break end
  cx.layout:resize(pane,"right",cells)
  local nextShape=cx.session:layout(tab)
  local after=nextShape and M.share(nextShape.root,pane)
  if not after or after==current then break end
  cells=(want-after)*cells/(after-current)
  current=after
 end
end

local function ratioAt(node,pane)
 if not node or node.pane then return nil end
 if node[1].pane==pane then return node.ratio or 0.5 end
 return ratioAt(node[1],pane) or ratioAt(node[2],pane)
end

local function ratioTo(cx,tab,pane,dir,want)
 local r=ratioAt(cx.session:layout(tab).root,pane)
 local step=r and (want-r)*180 or 0
 for _=1,8 do
  if not r or math.abs(want-r)<0.000001 or math.abs(step)<0.000001 then break end
  cx.layout:resize(pane,dir,step)
  local after=ratioAt(cx.session:layout(tab).root,pane)
  if not after or after==r then break end
  step=(want-after)*step/(after-r)
  r=after
 end
end

-- The SDK inserts beside a leaf, not a whole subtree. Retile the existing
-- live panes in one callback to wrap the original tree in a real root split.
-- No programs are closed or relaunched; original content ratios are replayed.
function M.wrap(cx,tab,pane,tree,want)
 local snapshot=cx.layout:snapshot()
 local ok,err=pcall(function()
 local retained=M.first(tree)
 local function park(node)
  if node.pane then
   if node.pane~=retained then assert(cx.layout:park(node.pane),"Could not retain content pane") end
  else park(node[1]); park(node[2]) end
 end
 park(tree)
 local shape=cx.session:layout(tab)
 if not (shape.root.split=="right" and shape.root[1].pane==pane and shape.root[2].pane==retained) then
  assert(cx.layout:move(pane,retained,"left",{focus=false}),"Could not place sidebar")
 end
 local function seed(node,anchor,dir)
  local first=M.first(node)
  assert(cx.layout:unpark(first,{focus=false}),"Could not restore content pane")
  assert(cx.layout:move(first,anchor,dir,{focus=false}),"Could not place content pane")
  return first
 end
 local function expand(node)
  if node.pane then return end
  local first=M.first(node[1])
  local dir=if node.split=="right" then "right" else "down"
  seed(node[2],first,dir)
  ratioTo(cx,tab,first,dir,node.ratio or 0.5)
  expand(node[1]); expand(node[2])
 end
 ratioTo(cx,tab,pane,"right",want)
 expand(tree) end)
 if not ok then
  local restored,why=cx.layout:restore(snapshot)
  error(tostring(err) .. (if restored then " (layout restored)" else " (restore failed: " .. tostring(why) .. ")"))
 end
end

return M
