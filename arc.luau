local M = {}

local SIZE = 30
local CENTER = SIZE / 2
local RADIUS = 12.25
local STROKE = 2
local SECTION = 110
local STEP = 120
local CAP_ANGLE = math.deg(math.asin(STROKE / (2 * RADIUS)))

local DEFAULTS = {
	accent = "#bdc7d3",
	warn = "#d7aa58",
	bad = "#d66c73",
	track = "#8993a0",
}

local function valid_color(value)
	return type(value) == "string" and string.match(value, "^#%x%x%x%x%x%x$") ~= nil
end

local function color(colors, name)
	local value = if type(colors) == "table" then colors[name] else nil
	return if valid_color(value) then string.lower(value) else DEFAULTS[name]
end

local function fraction(limit)
	if type(limit) ~= "table" or limit.stale or type(limit.remaining) ~= "number" then return nil end
	local value = limit.remaining
	if value ~= value or value == math.huge or value == -math.huge then return nil end
	return math.clamp(value, 0, 1)
end

local function point(degrees)
	local radians = math.rad(degrees)
	return CENTER + RADIUS * math.cos(radians), CENTER + RADIUS * math.sin(radians)
end

local function path(start_degrees, sweep_degrees)
	local x1, y1 = point(start_degrees)
	local x2, y2 = point(start_degrees + sweep_degrees)
	return string.format("M %.3f %.3f A %.3f %.3f 0 0 1 %.3f %.3f", x1, y1, RADIUS, RADIUS, x2, y2)
end

local function fill_color(value, colors)
	if value <= 0.1 then return color(colors, "bad") end
	if value <= 0.25 then return color(colors, "warn") end
	return color(colors, "accent")
end

-- A 30px SVG ring with three 110-degree quota windows and 10-degree gaps.
-- Missing/invalid readings retain only their neutral track; they never imply fill.
function M.svg(limits, colors)
	if type(limits) ~= "table" then limits = {} end
	local paths = {}
	for index = 1, 3 do
		local start = -90 + (index - 1) * STEP
		table.insert(paths, string.format('<path d="%s" stroke="%s" stroke-opacity="0.28"/>', path(start, SECTION), color(colors, "track")))
		local value = fraction(limits[index])
		if value and value > 0 then
			-- Round caps extend beyond a path's endpoints; inset them so a full
			-- quota reaches the section edges without closing the 10-degree gaps.
			local sweep = math.max(0.5, SECTION * value - 2 * CAP_ANGLE)
			table.insert(paths, string.format('<path d="%s" stroke="%s"/>', path(start + CAP_ANGLE, sweep), fill_color(value, colors)))
		end
	end
	return string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"><g fill="none" stroke-width="%.1f" stroke-linecap="round">%s</g></svg>',
		SIZE, SIZE, SIZE, SIZE, STROKE, table.concat(paths)
	)
end

return M
