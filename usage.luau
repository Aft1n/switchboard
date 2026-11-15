local M = {}
local stale_after_ms = 10 * 60 * 1000

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value)
	return math.max(0, math.min(1, value))
end

local function nonempty(value)
	return type(value) == "string" and value ~= "" and value or nil
end

-- Mirrors OMP's resolveUsedFraction precedence over the normalized amount.
local function used_fraction(amount)
	if type(amount) ~= "table" then return nil end
	if finite(amount.usedFraction) then return amount.usedFraction end
	if finite(amount.used) and finite(amount.limit) and amount.limit > 0 then
		return amount.used / amount.limit
	end
	if amount.unit == "percent" and finite(amount.used) then return amount.used / 100 end
	if finite(amount.remainingFraction) then return 1 - amount.remainingFraction end
	return nil
end

-- Gregorian UTC date from Unix milliseconds; Luau has no os.date.
function M.reset_label(ms)
	if not finite(ms) or ms < 0 then return nil end
	local seconds = math.floor(ms/1000)
	local days = math.floor(seconds/86400)
	local z = days+719468
	local era = math.floor(z/146097)
	local doe = z-era*146097
	local yoe = math.floor((doe-math.floor(doe/1460)+math.floor(doe/36524)-math.floor(doe/146096))/365)
	local year = yoe+era*400
	local doy = doe-(365*yoe+math.floor(yoe/4)-math.floor(yoe/100))
	local mp = math.floor((5*doy+2)/153)
	local day = doy-math.floor((153*mp+2)/5)+1
	local month = mp+(if mp < 10 then 3 else -9)
	if month <= 2 then year += 1 end
	local hour = math.floor(seconds%86400/3600)
	local minute = math.floor(seconds%3600/60)
	return string.format("Resets %04d-%02d-%02d %02d:%02d UTC",year,month,day,hour,minute)
end

function M.reset_countdown(reset_at, now_ms)
	if not finite(reset_at) or not finite(now_ms) then return nil end
	local remaining = reset_at - now_ms
	if remaining <= 0 then return "Reset due" end
	if remaining < 60 * 1000 then return "Resets in <1m" end

	local minutes = math.ceil(remaining / 60000)
	local days = math.floor(minutes / 1440)
	local hours = math.floor(minutes % 1440 / 60)
	local rest = minutes % 60
	if days > 0 then
		return "Resets in " .. days .. "d" .. (if hours > 0 then " " .. hours .. "h" else "")
	elseif hours > 0 then
		return "Resets in " .. hours .. "h" .. (if rest > 0 then " " .. rest .. "m" else "")
	end
	return "Resets in " .. rest .. "m"
end

local function identity_key(report, scope)
	local metadata = if type(report.metadata) == "table" then report.metadata else nil
	local parts = {}
	for _, field in {"email", "accountId", "projectId", "orgId"} do
		local value = if metadata then nonempty(metadata[field]) else nil
		if value then table.insert(parts, field .. "=" .. value) end
	end
	if #parts == 0 and scope then
		for _, field in {"accountId", "projectId", "orgId"} do
			local value = nonempty(scope[field])
			if value then table.insert(parts, field .. "=" .. value) end
		end
	end
	return table.concat(parts, "\0")
end

local function stale_report(now, fetched_at, reset_at)
	return now ~= nil and (
		(fetched_at ~= nil and now - fetched_at > stale_after_ms)
		or (reset_at ~= nil and reset_at <= now and (fetched_at == nil or fetched_at <= reset_at))
	)
end

local function newer_or_healthier(previous, candidate)
	if previous.stale ~= candidate.stale then return not candidate.stale end
	local previous_fetched, candidate_fetched = previous.fetched_at, candidate.fetched_at
	if finite(previous_fetched) and finite(candidate_fetched) and previous_fetched ~= candidate_fetched then
		return candidate_fetched > previous_fetched
	elseif finite(previous_fetched) ~= finite(candidate_fetched) then
		return finite(candidate_fetched)
	end
	if finite(previous.reset_at) and finite(candidate.reset_at) and previous.reset_at ~= candidate.reset_at then
		return candidate.reset_at > previous.reset_at
	end
	-- Equal or missing timestamps do not prove which report is newer, so keep
	-- the conservative most-used value.
	return candidate.remaining < previous.remaining
end

function M.scan(decoded, now_ms)
	local rows, positions = {}, {}
	if type(decoded) ~= "table" or type(decoded.reports) ~= "table" then return rows end
	local now = if finite(now_ms) then now_ms elseif finite(decoded.generatedAt) then decoded.generatedAt else nil

	for _, report in decoded.reports do
		local provider = if type(report) == "table" then nonempty(report.provider) else nil
		if provider and type(report.limits) == "table" then
			for _, limit in report.limits do
				if type(limit) == "table" then
					local used = used_fraction(limit.amount)
					if finite(used) then
						local window = if type(limit.window) == "table" then limit.window else nil
						local scope = if type(limit.scope) == "table" then limit.scope else nil
						local window_label = if window then nonempty(window.label) else nil
						local label = nonempty(limit.label) or window_label or provider
						local remaining = clamp(1 - used)
						local reset_at = if window and finite(window.resetsAt) then window.resetsAt else nil
						local fetched_at = if finite(report.fetchedAt) then report.fetchedAt else nil
						local stale = stale_report(now, fetched_at, reset_at)
						local row = {
							provider = provider,
							label = label,
							remaining = remaining,
							reset_at = reset_at,
							fetched_at = fetched_at,
							stale = stale,
							detail = (window_label or label) .. (if reset_at then " · " .. M.reset_label(reset_at) else ""),
						}
						-- A provider can report the same window for several accounts. Keep each
						-- identity separate, then let a newer report replace its older value.
						local window_key = (window and nonempty(window.id)) or (scope and nonempty(scope.windowId)) or window_label or label
						local identity = identity_key(report, scope)
						local qualifier = if scope then nonempty(scope.sharedGroup) or nonempty(scope.tier) or nonempty(scope.modelId) else nil
						local key = provider .. "\0" .. identity .. "\0" .. label .. "\0" .. window_key .. "\0" .. (qualifier or "")
						local position = positions[key]
						if position == nil then
							table.insert(rows, row)
							positions[key] = #rows
						else
							local previous = rows[position]
							if newer_or_healthier(previous, row) then
								rows[position] = row
							end
						end
					end
				end
			end
		end
	end

	return rows
end

function M.reset_due(rows, now_ms)
	if type(rows) ~= "table" or not finite(now_ms) then return false end
	for _, row in rows do
		if type(row) == "table" and finite(row.reset_at) and row.reset_at <= now_ms
			and (not finite(row.fetched_at) or row.fetched_at <= row.reset_at) then
			return true
		end
	end
	return false
end

return M
