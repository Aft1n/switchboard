-- Child identities come only from OMP task metadata belonging to this parent.
local M={}
local SORT_MS=30000
-- Finished children remain as history for half an hour, then leave the sidebar.
local HISTORY_MS=1800000
local function text(v,n)
 if type(v)~="string" or v=="" then return nil end
 local stop=utf8.offset(v,(n or 180)+1)
 return if stop then string.sub(v,1,stop-1) else v
end
local function status(row,result)
 local s=row.status
 if s=="running" or s=="working" then return "working" end
 if s=="pending" or s=="queued" then return "queued" end
 if s=="waiting_input" or s=="idle" then return s end
 if s=="error" or s=="failed" or s=="aborted" then return "failed" end
 if s=="success" or s=="completed" or s=="done" then return "done" end
 if result and type(row.exitCode)=="number" then return if row.exitCode==0 then "done" else "failed" end
 return "unknown"
end
function M.scan(messages,previous,now,wall)
 local rows,positions,before,rank={},{},{},{}
 local function put(row,result)
  if type(row)~="table" then return end
  local id=text(row.id,256)
  if not id or string.find(id,"[%c%s]") then return end
  local pos=positions[id]
  local prior=pos and rows[pos] or {}
  local model=row.resolvedModelIdentity or row.resolvedModel or row.modelOverride or row.model
  if type(model)=="table" then model=model.id end
  local state=status(row,result)
  -- OMP's task result is the spawn snapshot and its pending rows never update, so
  -- it must not demote a state a live surface (or a result) already reported.
  if not result and state=="queued" and prior.state and prior.state~="queued" and prior.state~="unknown" then return end
  local item={id=id,title=text(row.description) or text(row.assignment) or text(row.task) or text(row.agent) or prior.title or id,
   state=state,model=text(model,100) or prior.model,
   step=text(row.stage) or text(row.lastIntent) or prior.step,
   detail=text(row.output,1200) or prior.detail,error=if state=="failed" then text(row.error,500) or prior.error else nil}
  if pos then rows[pos]=item else table.insert(rows,item);positions[id]=#rows;rank[id]=#rows end
 end
 -- Retain known children across short or empty transcript windows. Ordering on
 -- means previous rows arrive newest bucket first, so the 32-row trim needs them
 -- oldest first; without it, keep the original insertion order.
 local kept=previous or {}
 local first,last,stride=1,#kept,1
 if now~=nil then first,last,stride=#kept,1,-1 end
 for i=first,last,stride do
  local row=kept[i]
  if type(row)=="table" and type(row.id)=="string" then
   if now~=nil or wall~=nil then row=table.clone(row) end
   table.insert(rows,row);positions[row.id]=#rows;before[row.id]=row;rank[row.id]=i
  end
 end
 for _,message in (if type(messages)=="table" then messages else {}) do
  if type(message)=="table" and type(message.tools)=="table" then
   for _,tool in message.tools do
    if type(tool)=="table" and type(tool.name)=="string" and string.lower(tool.name)=="task"
     and type(tool.metadata)=="table" then
     local meta=tool.metadata
     for _,row in (if type(meta.progress)=="table" then meta.progress else {}) do put(row,false) end
     for _,row in (if type(meta.results)=="table" then meta.results else {}) do put(row,true) end
    elseif type(tool)=="table" and type(tool.name)=="string" and string.lower(tool.name)=="wait"
     and type(tool.metadata)=="table" then
     -- wait results carry finished/running agents that the spawn snapshot never updates.
     local jobs=tool.metadata.jobs
     if type(jobs)~="table" then jobs=if type(tool.metadata.details)=="table" then tool.metadata.details.jobs else nil end
     for _,job in (if type(jobs)=="table" then jobs else {}) do
      if type(job)=="table" then
       local id=text(job.id,256)
       if id and not string.find(id,"^bg_") and type(job.status)=="string" then put({id=id,status=job.status},false) end
      end
     end
    end
   end
  end
 end
 if now~=nil or wall~=nil then
  for _,row in rows do
   local old=before[row.id]
   local same=old and old.updated_at~=nil and row.title==old.title and row.state==old.state and row.model==old.model
    and row.step==old.step and row.detail==old.detail and row.error==old.error
   if same then
    if now~=nil then row.updated_at=old.updated_at end
    if wall~=nil then row.wall_at=old.wall_at or wall end
   else
    if now~=nil then row.updated_at=now end
    if wall~=nil then row.wall_at=wall end
   end
  end
 end
 -- Keep the most recent 32 identities; rendering and cached payloads stay bounded.
 if #rows>32 then rows=table.move(rows,#rows-31,#rows,1,{}) end
 -- Newest 30s bucket first; equal buckets keep their previous order via rank.
 local keyed={}
 for _,row in rows do keyed[#keyed+1]={row=row,bucket=math.floor((row.updated_at or 0)/SORT_MS),rank=rank[row.id] or 0} end
 table.sort(keyed,function(a,b)
  if a.bucket~=b.bucket then return a.bucket>b.bucket end
  return a.rank<b.rank
 end)
 rows={}
 for _,item in keyed do table.insert(rows,item.row) end
 return rows
end
-- Drop spawn-snapshot-only rows and finished history older than HISTORY_MS.
function M.clean(rows,wall_now)
 if wall_now==nil then return rows or {} end
 if type(rows)~="table" then return {} end
 local out={}
 for _,row in rows do
  if type(row)~="table" then
  elseif row.state=="queued" then
   -- OMP's task result never updates its pending rows; they are not live children.
  elseif row.state=="working" or row.state=="waiting_input" then
   table.insert(out,row)
  elseif type(row.wall_at)~="number" or wall_now-row.wall_at<HISTORY_MS then
   -- Rows from before the wall clock was recorded get one lease, then age out.
   table.insert(out,row)
  end
 end
 return out
end
function M.from_surface(surface,previous,now,wall)
 local found,visited={},0
 local function walk(node,depth)
  if type(node)~="table" or depth>64 or visited>=2000 then return end
  visited+=1
  local p=node.p
  if node.k=="agent" and type(p)=="table" then
   local id=text(p.name,256)
   -- Nested registry ids use dots; OMP formats their labels as A>B. Restore
   -- only when the exact raw suffix is confirmed by the native row key.
   if id and type(node.id)=="string" then
    local raw=string.gsub(id,">",".")
    if string.sub(node.id,-#raw-1)=="."..raw or string.sub(node.id,-#raw-1)=="/"..raw then id=raw end
   end
   if id then
    local step,err
    local function latest(n,d)
     if type(n)~="table" or d>16 then return end
     if n.k=="tool" and type(n.p)=="table" then step=text(n.p.intent) or text(n.p.title) or step end
     if type(n.p)=="table" and n.p.role=="omp.tool.error" then
      local parts={};for _,span in n.p.spans or {} do if type(span.t)=="string" then table.insert(parts,span.t) end end
      err=text(table.concat(parts),500)
     end
     for _,c in n.c or {} do latest(c,d+1) end
    end
    latest(node,0)
    table.insert(found,{id=id,description=text(p.name) or text(p.task),agent=p.agent,
     status=p.status,resolvedModel=p.model,lastIntent=step,error=err,output=text(p.task,1200)})
   end
  end
  for _,child in node.c or {} do walk(child,depth+1) end
 end
 if type(surface)=="table" then
  walk(surface.main or surface,0);walk(surface.dock,0);walk(surface.layer,0)
 end
 return M.scan({{tools={{name="task",metadata={progress=found}}}}},previous,now,wall)
end

function M.collect(messages,surface,previous,now,wall)
 return M.from_surface(surface,M.scan(messages,previous,now,wall),now,wall)
end

-- Native task rows can occur thousands of siblings into long transcripts.
function M.task_roots(surface)
 if type(surface)~="table" then return {} end
 local root=surface.main or surface
 local ids={}
 for i=#(root.c or {}),1,-1 do
  local node=root.c[i]
  if node.k=="tool" and type(node.p)=="table" and node.p.role=="omp.tool.task" and type(node.id)=="string" then
   table.insert(ids,node.id)
   if #ids==8 then break end
  end
 end
 return ids
end

-- CustomEditor owns native focus:<id> actions, including for settled workers.
function M.focus_event(surface,id)
 if type(id)~="string" or id=="" or string.find(id,"[%c%s]") then return nil end
 local function find(node,depth)
  if type(node)~="table" or depth>32 then return nil end
  if type(node.p)=="table" and node.p.role=="omp.editor" and type(node.id)=="string" then
   return {ev="action",sf=surface.surface and surface.surface.id,id=node.id,act="focus:"..id}
  end
  for _,child in node.c or {} do local event=find(child,depth+1);if event then return event end end
  return nil
 end
 if type(surface)~="table" then return nil end
 return find(surface.dock or surface.main or surface,0)
end
-- Read OMP's own return action; never guess its main-session registry id.
function M.parent_event(surface)
 if type(surface)~="table" then return nil end
 local function find(node,depth)
  if type(node)~="table" or depth>32 then return nil end
  local p=node.p or {}
  local action=p.actions and p.actions.click
  if p.role=="omp.composer.exit" and type(action)=="string" and string.sub(action,1,6)=="focus:" then
   return {ev="action",sf=surface.surface and surface.surface.id,id=node.id,act=action}
  end
  for _,child in node.c or {} do local event=find(child,depth+1);if event then return event end end
  return nil
 end
 return find(surface.dock or surface.main or surface,0)
end
return M
