local progress = require("./progress")
local unicode = progress.scan({{tools={{name="bash",intent=string.rep("ї",200),status="running"}}}})
assert(utf8.len(unicode.steps[1].label) == 180, "Long step labels retain valid Unicode")
local p = progress.scan({
	{role="user",text="Ship it"},
	{role="assistant",tools={
		{name="todo",target="1/4",status="done"},
		{name="bash",intent="Run the backend tests",status="done",key="a"},
		{name="write",intent="Update the documentation",status="running",key="b"},
	}},
})
assert(p.todo.done == 1 and p.todo.total == 4)
assert(#p.steps == 2 and p.steps[2].label == "Update the documentation")
assert(p.steps[2].status == "running")
assert(p.steps[1].tool == "bash" and p.steps[2].tool == "write", "Steps keep the tool name for the card icon")
local fresh = progress.scan({{role="user",text="A different task"}}, p)
assert(fresh.todo and fresh.todo.done == 1 and #fresh.steps == 0, "A steer keeps an unfinished todo and clears old steps")
local finished_list = progress.scan({{role="assistant",tools={{name="todo",target="4/4"}}},{role="user",text="Next task"}})
assert(finished_list.todo == nil, "A finished todo list is dropped when new work starts")
local retained = progress.scan({{role="assistant",tools={{name="bash",intent="Check the result",status="done"}}}},p)
assert(retained.todo.done == 1, "A long turn retains its latest todo count")
assert(progress.scan({{tools={{name="todo",target="9/2"}}}}).todo == nil)
local span_count = progress.scan({{tools={{name="todo",target={{t="3/8"}}}}}})
assert(span_count.todo.done == 3 and span_count.todo.total == 8, "Todo counts parse from transcript target spans")
local failed = progress.scan({{tools={{name="bash",title={{t="Tests"}},status="done",tone="error"}}}})
assert(failed.steps[1].label == "Tests" and failed.steps[1].status == "failed")
local after_prompt = progress.scan({{role="assistant",tools={{name="bash",intent="New turn",status="running"}}}}, fresh)
assert(after_prompt.todo and after_prompt.todo.done == 1, "An unfinished todo survives into the new turn")
assert(#after_prompt.steps == 1 and after_prompt.steps[1].label == "New turn", "A new prompt cannot restore prior tool steps")
local absent = progress.scan(nil, p)
assert(absent.todo.done == 1 and #absent.steps == 2, "A missing transcript keeps the last valid snapshot")
local malformed = progress.scan({false,{role="assistant",tools="invalid"}}, p)
assert(malformed.todo.done == 1 and #malformed.steps == 2, "Malformed transcript entries are ignored safely")
local malformed_previous = progress.scan({}, 7)
assert(malformed_previous.todo == nil and #malformed_previous.steps == 0, "Malformed prior snapshots are ignored safely")
local huge = progress.scan({{tools={{name="todo",target="999999999999999999999999999999999999/999999999999999999999999999999999999"}}}})
assert(huge.todo == nil, "Inexact todo counts are ignored")
print("Switchboard progress checks passed")

local excerpt=progress.scan({{role="assistant",text=string.rep("ї",450)}})
assert(utf8.len(excerpt.response)==401)
assert(progress.scan({{role="user",text="new"}},excerpt).response==nil)

local reads={
 [1]={state="working",dirty=false,read_at=12000},
 [2]={state="working",dirty=false,read_at=10500},
 [3]={state="idle",dirty=true,read_at=-math.huge},
}
assert(progress.next_read(reads,15000,1)==3,"Unread idle agent must not starve behind running work")
reads[3].dirty=false;reads[3].read_at=15000
assert(progress.next_read(reads,15000,1)==2,"Oldest due read must win before focused running work")
reads[3].read_at=0
assert(progress.next_read(reads,18000,1)==2)
reads[2].read_at=18000
assert(progress.next_read(reads,18000,1)==1)
reads[1].read_at=18000
assert(progress.next_read(reads,18000,1)==3,"An overdue idle agent must get a refresh")
print("fair activity sampling checks passed")

local sdk=progress.scan({{role="assistant",text="",tools={
 {name="bash",target="git status",status="done",metadata={}},
 {name="todo",target="3/5",status="done",metadata={}},
}}})
assert(sdk.steps[1].label=="git status" and sdk.steps[1].status=="done")
assert(sdk.todo.done==3 and sdk.todo.total==5)
local textOnly=progress.scan({{role="user",text="Explain this"},{role="assistant",text="A prose answer",tools={}}})
assert(#textOnly.steps==0 and textOnly.todo==nil)
print("SDK tool and conversation-only checks passed")

local many_tools={}
for i=1,10000 do
	table.insert(many_tools,{name="bash",intent="Step " .. i,status="done"})
end
local many=progress.scan({{role="assistant",tools=many_tools}})
assert(#many.steps==3)
assert(many.steps[1].label=="Step 9998" and many.steps[2].label=="Step 9999" and many.steps[3].label=="Step 10000",
	"only the exact last three steps are retained")

local long_span={
	{
		role="assistant",
		tools={{
			name="bash",
			intent={{t=string.rep("界",160)},{t=string.rep("🙂",10000) .. "\nignored " .. string.rep("discard",10000)}},
			status="done",
		}},
	},
}
local span_snapshot=progress.scan(long_span)
assert(span_snapshot.steps[1].label==string.rep("界",160) .. string.rep("🙂",20),"long Unicode spans keep the meaningful first line prefix")

local long_string=progress.scan({{tools={{name="bash",intent="First line\n" .. string.rep("界",10000),status="done"}}}})
assert(long_string.steps[1].label=="First line","a long string keeps its short first line")

local long_tail=progress.scan({{tools={{name="bash",intent={{t="First line\n"},{t=string.rep("界",10000)}},status="done"}}}})
assert(long_tail.steps[1].label=="First line","a long span tail cannot hide its meaningful first line")

local cached={steps={{label="Checking files",status="done"}},todo={done=2,total=5},response="Working"}
local empty=progress.scan({},cached)
assert(empty.steps[1].label=="Checking files")
assert(empty.todo.done==2 and empty.todo.total==5)
assert(empty.response=="Working")
local newturn=progress.scan({{role="user",text="Next task"}},cached)
assert(#newturn.steps==0 and newturn.todo.done==2)
print("empty activity reads retain progress; new turns reset it")

local complete={todo={done=5,total=5}}
assert(progress.visible_todo(complete,"idle",100,600099)~=nil)
assert(progress.visible_todo(complete,"idle",100,600100)==nil)
assert(progress.visible_todo(complete,"working",100,600100)~=nil)
assert(progress.visible_todo({todo={done=2,total=5}},"idle",100,600100)~=nil)
print("completed progress expires after ten idle minutes")

local last={todo={done=6,total=7},steps={{label="Final verification",status="done"}}}
local final=progress.sample({{role="user",text="follow up"}},last,"idle",{
 role="GenericContainer",children={{role="Button",name="Todos, 7 of 7 done"}}
})
assert(final.todo.done==7 and final.todo.total==7)
assert(final.steps[1].label=="Final verification")
local live=progress.sample({{role="user",text="new work"}},last,"working",nil)
assert(live.todo.done==6 and #live.steps==0)
assert(progress.from_view({name="Todos, 8 of 7 done"})==nil)
print("finished cards retain steps and use native completed todo counts")

assert(progress.next_read({[9]={state="idle",dirty=false,read_at=0,subagents={{id="Worker",state="working"}}}},3000,nil)==9,"Live children must refresh while their parent is idle")
return true
