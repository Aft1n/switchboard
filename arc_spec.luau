local arc = require("./arc")

local function count(text, needle)
	local _, n = string.gsub(text, needle, "")
	return n
end

local svg = arc.svg({
	{remaining=1},
	{remaining=0.2},
	{remaining=0},
}, {accent="#123456", warn="#abcdef", bad="#ff0000", track="#010203"})

assert(string.find(svg, '<svg xmlns="http://www.w3.org/2000/svg"', 1, true))
assert(count(svg, '<path d=') == 5, "three tracks plus fills for the nonzero readings")
assert(count(svg, 'stroke="#010203"') == 3, "each quota window has a neutral track")
assert(count(svg, 'stroke="#123456"') == 1, "healthy quota uses the accent")
assert(count(svg, 'stroke="#abcdef"') == 1, "low quota uses the warning color")
assert(count(svg, 'stroke="#ff0000"') == 0, "zero quota has no visible fill")
assert(string.find(svg, 'stroke-linecap="round"', 1, true), "arcs have smooth round ends")
assert(string.find(svg, '0 0 1 26.511 19.190', 1, true), "first section spans 110 degrees")
local half = arc.svg({{remaining=0.5}})
assert(string.find(half, '0 0 1 24.428 7.178', 1, true), "round caps preserve the half-quota angle")

local unknown = arc.svg({{remaining="not-a-number"}})
assert(count(unknown, '<path d=') == 3, "unknown readings show tracks without filled quota")
assert(count(unknown, 'stroke="#bdc7d3"') == 0)

local clamped = arc.svg({{remaining=2}, {remaining=-1}, {remaining=0.2}})
assert(count(clamped, '<path d=') == 5, "out-of-range readings are clamped")
assert(count(clamped, 'stroke="#bdc7d3"') == 1)
assert(count(clamped, 'stroke="#d7aa58"') == 1)

local malformed = arc.svg(false)
assert(count(malformed, '<path d=') == 3, "bad input still yields three empty tracks")

print("Switchboard arc checks passed")
return true
