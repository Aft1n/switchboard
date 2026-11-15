local M = {}
local MAX_COUNT = 9007199254740991
local MAX_STEPS = 3
-- The visible label is 180 codepoints; keep one extra to preserve the old trim.
local MAX_LABEL_CHARS = 181

local function count(value)
	return type(value) == "number" and value >= 0 and value <= MAX_COUNT and value % 1 == 0
end

local function plain(value, limit)
	if type(value) == "string" then
		if limit then
			local stop = utf8.offset(value, limit + 1)
			if stop then return string.sub(value, 1, stop - 1) end
		end
		return value
	end
	if type(value) ~= "table" then return "" end
	local out = {}
	local chars = 0
	for _, span in value do
		if type(span) == "table" and type(span.t) == "string" then
			local text = span.t
			if limit then
				local remaining = limit - chars
				if remaining <= 0 then break end
				local stop = utf8.offset(text, remaining + 1)
				if stop then text = string.sub(text, 1, stop - 1) end
				chars += utf8.len(text) or 0
				if text ~= "" then table.insert(out, text) end
				if chars >= limit then break end
			else
				table.insert(out, text)
			end
		end
	end
	return table.concat(out)
end

local function append_step(steps, step)
	local n = #steps
	if n < MAX_STEPS then
		steps[n + 1] = step
	else
		steps[1], steps[2], steps[3] = steps[2], steps[3], step
	end
end

function M.scan(messages, previous)
	local todo, prior_steps
	local response=if type(previous)=="table" then previous.response else nil
	if type(previous) == "table" then
		local prior = previous.todo
		if type(prior) == "table" and count(prior.done) and count(prior.total) and prior.total > 0 and prior.done <= prior.total then
			todo = {done=prior.done,total=prior.total}
		end
		prior_steps = {}
		if type(previous.steps) == "table" then
			for _, step in previous.steps do
				local status = if type(step) == "table" then step.status else nil
				if type(step) == "table" and type(step.label) == "string" and step.label ~= ""
					and (status == "failed" or status == "done" or status == "running" or status == "unknown") then
					append_step(prior_steps, {label=step.label, key=if type(step.key) == "string" then step.key else nil, tool=if type(step.tool) == "string" then step.tool else nil, status=status})
				end
			end
		end
	end
	local steps = {}
	local reset = false
	local recent -- steps of the latest earlier turn that had any, shown by an idle card whose newest turn used no tools
	if type(messages) == "table" then
		for _, message in messages do
			if type(message) == "table" then
				if message.role == "user" then
					-- A todo list is session state: a mid-run steer must not wipe it. Only a
					-- finished list is dropped when the next prompt starts new work.
					if todo and todo.done >= todo.total then todo = nil end
					if #steps > 0 then recent = steps end
					steps, reset, response = {}, true, nil
				end
				if message.role == "assistant" and type(message.text)=="string" and message.text~="" then
					response=message.text
					local stop=utf8.offset(response,401)
					if stop then response=string.sub(response,1,stop-1) .. "…" end
				end
				if type(message.tools) == "table" then
					for _, tool in message.tools do
						if type(tool) == "table" then
							if tool.name == "todo" then
								local done, total = string.match(plain(tool.target), "^(%d+)/(%d+)$")
								if done and total then
									local d, t = tonumber(done), tonumber(total)
									if count(d) and count(t) and t > 0 and d <= t then todo = {done=d,total=t} end
								end
							else
								local label = plain(tool.intent, MAX_LABEL_CHARS)
								if label == "" then label = plain(tool.target, MAX_LABEL_CHARS) end
								if label == "" then label = plain(tool.title, MAX_LABEL_CHARS) end
								if label == "" then label = plain(tool.name, MAX_LABEL_CHARS) end
								label = string.match(label, "[^\n]+") or ""
									local stop = utf8.offset(label,MAX_LABEL_CHARS)
								if stop then label = string.sub(label,1,stop-1) end
								if label ~= "" then
									local failed = tool.status == "error" or tool.status == "failed" or tool.tone == "error" or tool.tone == "bad"
									local done = tool.status == "done" or tool.status == "success" or tool.status == "completed"
									append_step(steps, {
										label=label, key=if type(tool.key) == "string" then tool.key else nil,
										tool=if type(tool.name) == "string" then tool.name else nil,
										status=if failed then "failed" elseif done then "done" elseif tool.status == "running" then "running" else "unknown",
									})
								end
							end
						end
					end
				end
			end
		end
	end
	if #steps == 0 and not reset then steps = prior_steps or {} end
	return {todo=todo,steps=steps,response=response,recent_steps=recent}
end

-- Prefer the latest visible native todo summary, including the composer summary.
function M.from_view(root)
 local todo,visited=nil,0
 local function walk(node,depth)
  if type(node)~="table" or depth>64 or visited>=5000 then return end
  visited+=1
  local name=node.name
  if type(name)=="string" then
   local done,total=string.match(name,"^Todos, (%d+) of (%d+) done$")
   if not done then done,total=string.match(name,"^Todo, (%d+)/(%d+)") end
   local d,t=tonumber(done),tonumber(total)
   if count(d) and count(t) and t>0 and d<=t then todo={done=d,total=t} end
  end
  for _,child in node.children or {} do walk(child,depth+1) end
 end
 walk(root,0)
 return todo
end
function M.sample(messages,previous,state,native_view)
 local result=M.scan(messages,previous)
 if state=="idle" and #result.steps==0 and result.recent_steps and #result.recent_steps>0 then result.steps=result.recent_steps end
 result.recent_steps=nil
 local native=M.from_view(native_view)
 if native then result.todo=native end
 if state=="idle" and type(previous)=="table" then
  if not result.todo then result.todo=previous.todo end
  if #result.steps==0 then result.steps=previous.steps or {} end
 end
 return result
end

-- Earliest due read wins across all hosts. State priority alone can keep
-- idle or newly discovered agents unread while several agents are running.
function M.next_read(records,now,focused)
 local pick,deadline,priority
 for pane,record in records do
  local due=if record.read_at==-math.huge then -math.huge elseif record.dirty then record.read_at else record.read_at+(if record.state=="working" or #(record.subagents or {})>0 then 3000 else 15000)
  local rank=if pane==focused then 0 elseif record.state=="waiting_input" then 1 elseif record.state=="working" then 2 else 3
  if due<=now and (not pick or due<deadline or (due==deadline and rank<priority)) then
   pick,deadline,priority=pane,due,rank
  end
 end
 return pick
end

function M.visible_todo(snapshot,state,completed_at,now)
 local todo=type(snapshot)=="table" and snapshot.todo
 if not todo then return nil end
 if (state=="idle" or state=="done") and todo.done==todo.total
  and type(completed_at)=="number" and type(now)=="number" and now-completed_at>=600000 then return nil end
 return todo
end
return M
