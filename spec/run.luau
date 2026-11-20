--!strict
local h = require("./harness")
require("./subagents_spec")
require("../agent_history_spec")
require("../agent_sessions_spec")
require("../agent_state_spec")
require("../arc_spec")
require("../close_target_spec")
require("../keyboard_spec")
require("../tree_history_spec")
require("../launchers_spec")
require("../model_view_spec")
require("../placement_spec")
require("../progress_spec")
require("../project_colors_spec")
require("../render_cache_spec")
require("../section_sizes_spec")
require("../terminal_agents_spec")
require("../usage_spec")
require("../vibe_spec")
require("../tree_flip_spec")
require("../workspace_order_spec")
require("../workspace_recency_spec")

local _, failed, failures = h.run()
if failed > 0 then
	for _, failure in failures do
		local line = string.gsub(failure, "\n", " ")
		print(line)
	end
	error(tostring(failed) .. " failing test(s)")
end

return true
