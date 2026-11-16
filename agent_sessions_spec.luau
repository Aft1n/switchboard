local sessions=require("./agent_sessions")
local function eq(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end

local FIXTURE=[[{
  "sessions": [
    {
      "blocks": [
        {
          "args": [
            "{\"pane\": 99, \"cwd\": \"/fake\", \"omp_session_file\": \"/fake/2026-01-01T00-00-00-000Z_00000000-0000-0000-0000-000000000000.jsonl\"}"
          ]
        }
      ]
    }
  ],
  "panes": [
    {
      "pane": 1,
      "args": [
        "-l"
      ],
      "cwd": "/Users/x/repo",
      "omp_session_file": null
    },
    {
      "pane": 2,
      "args": [
        "{\"text\": \"escaped \\n and \\\" quote: pane 1 omp_session_file /fake/x.jsonl\"}"
      ],
      "cwd": "/Users/x/repo",
      "title": "Fix \"auth\" flow",
      "omp_session_file": "/Users/x/.omp/agent/sessions/-x-repo/2026-11-14T15-43-29-625Z_01a1daba-5f59-7409-bcad-f6e1c2a0dc7e.jsonl"
    },
    {
      "pane": 3,
      "cwd": "/Users/x/repo",
      "omp_session_file": ""
    }
  ],
  "windows": [
    {
      "pane": 4,
      "cwd": "/outside",
      "omp_session_file": "/outside/2026-11-14T15-43-29-625Z_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
    }
  ]
}
]]

local parsed=sessions.parse(FIXTURE)
eq(parsed["1"],nil) -- null session file
eq(parsed["3"],nil) -- empty session file
eq(parsed["4"],nil) -- outside the top-level panes array
eq(parsed["99"],nil) -- only inside an escaped args string
eq(parsed["2"].session,"01a1daba-5f59-7409-bcad-f6e1c2a0dc7e")
eq(parsed["2"].cwd,"/Users/x/repo")
eq(parsed["2"].title,'Fix "auth" flow')

-- The native-decoded walk must agree with the line parser on the same panes.
local decoded=sessions.from_decoded({panes={
  {pane=1,cwd="/Users/x/repo",omp_session_file=nil},
  {pane=2,cwd="/Users/x/repo",title='Fix "auth" flow',omp_session_file="/Users/x/.omp/agent/sessions/-x-repo/2026-11-14T15-43-29-625Z_01a1daba-5f59-7409-bcad-f6e1c2a0dc7e.jsonl"},
  {pane=3,cwd="/Users/x/repo",omp_session_file=""},
}})
eq(decoded["1"],nil)
eq(decoded["3"],nil)
eq(decoded["2"].session,"01a1daba-5f59-7409-bcad-f6e1c2a0dc7e")
eq(decoded["2"].cwd,"/Users/x/repo")
eq(decoded["2"].title,'Fix "auth" flow')
eq(sessions.from_decoded({}),nil)

-- Same pane, different non-empty session in the same cwd is OMP /new.
eq(sessions.new_session({session="A",cwd="/p",title="x"},{session="B",cwd="/p",title="x"}),true)
eq(sessions.new_session({session="A",cwd="/p"},{session="A",cwd="/p"}),false)
eq(sessions.new_session({session="A",cwd="/p"},{session="B",cwd="/q"}),false)
eq(sessions.new_session(nil,{session="B",cwd="/p"}),false) -- first mapping after reload/window start
eq(sessions.new_session({session="",cwd="/p"},{session="B",cwd="/p"}),false)

-- Malformed or truncated output yields only valid pairs, never an error.
local truncated='  "panes": [\n    {\n      "pane": 8,\n      "cwd": "/a",\n      "omp_session_file": "/a/2026_x.jsonl"'
eq(#sessions.parse(truncated),0)
eq(#sessions.parse(nil),0)
eq(sessions.parse(truncated)["7"],nil)
print("agent sessions checks passed")
return true
