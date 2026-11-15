local usage = require("./usage")

local function eq(actual, expected)
	assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function close(actual, expected)
	assert(math.abs(actual - expected) < 1e-9, tostring(actual) .. " ~= " .. tostring(expected))
end

local rows = usage.scan({reports={
	{provider="openai-codex",limits={
		{label="5h",amount={remainingFraction=0.62},window={label="5 hour",resetsAt=1780000000000}},
		{label="7d",amount={usedFraction=0.75},window={label="7 day"}},
		{label="Requests",amount={used=30,limit=100},window={label="Monthly"}},
		{label="Quota",amount={unit="percent",used=15},window={label="Cycle"}},
		{label="No quota",amount={used=50,unit="tokens"},window={label="Daily"}},
	}},
	{provider="openai-codex",limits={
		{label="5h",amount={usedFraction=0.8},window={label="5 hour",resetsAt=1780000100000}},
	}},
	{provider="anthropic",limits={
		{label="5h",amount={usedFraction=1.2},window={label="5 hour"}},
	}},
}})

eq(#rows, 5)
eq(rows[1].provider, "openai-codex")
eq(rows[1].label, "5h")
eq(rows[1].detail, "5 hour · Resets 2026-05-28 20:28 UTC")
close(rows[1].remaining, 0.2)
eq(rows[1].reset_at, 1780000100000)
close(rows[2].remaining, 0.25)
close(rows[3].remaining, 0.7)
close(rows[4].remaining, 0.85)
eq(rows[5].provider, "anthropic")
eq(rows[5].remaining, 0)

eq(#usage.scan({reports={
	{provider="openai-codex",limits={{label="unknown",amount={unit="tokens",used=50}}}},
}}), 0, "limits without a remaining share do not invent one")
eq(#usage.scan({reports="invalid"}), 0)
eq(#usage.scan(nil), 0)

local now_ms = 1800000000000
local reset_at = now_ms - 60000
local restored = usage.scan({generatedAt=now_ms,reports={
	{provider="openai-codex",fetchedAt=reset_at-1000,limits={
		{label="5h",amount={usedFraction=1},window={label="5 hour",resetsAt=reset_at}},
	}},
	{provider="openai-codex",fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=0.2},window={label="5 hour",resetsAt=reset_at+5*60*60*1000}},
	}},
}})
eq(#restored,1)
close(restored[1].remaining,0.8,"fresh post-reset report replaces stale depletion")
eq(restored[1].fetched_at,now_ms-1000)
eq(restored[1].stale,false)

local fresh_exhausted = usage.scan({generatedAt=now_ms,reports={
	{provider="openai-codex",fetchedAt=now_ms-2000,limits={
		{label="5h",amount={usedFraction=0.2},window={label="5 hour",resetsAt=now_ms+100000}},
	}},
	{provider="openai-codex",fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=1},window={label="5 hour",resetsAt=now_ms+100000}},
	}},
}})
eq(#fresh_exhausted,1)
close(fresh_exhausted[1].remaining,0,"fresh exhausted account remains the conservative choice")
eq(fresh_exhausted[1].stale,false)

local aged = usage.scan({generatedAt=now_ms,reports={{
	provider="openai-codex",fetchedAt=now_ms-600001,limits={
		{label="5h",amount={usedFraction=0.1},window={label="5 hour",resetsAt=now_ms+100000}},
	},
}}})
eq(aged[1].stale,true,"reports older than ten minutes are stale")
eq(usage.scan({generatedAt=now_ms,reports={{
	provider="openai-codex",fetchedAt=now_ms-600000,limits={
		{label="5h",amount={usedFraction=0.1},window={label="5 hour",resetsAt=now_ms+100000}},
	},
}}})[1].stale,false,"ten minutes exactly is still fresh")
eq(usage.scan({generatedAt="invalid",reports={{
	provider="openai-codex",limits={
		{label="5h",amount={usedFraction=0.1},window={label="5 hour",resetsAt=reset_at}},
	},
}}})[1].stale,false,"without a finite clock, reset age is not inferred")
eq(usage.scan({generatedAt=now_ms+100000,reports={{
	provider="openai-codex",fetchedAt=reset_at-1,limits={
		{label="5h",amount={usedFraction=1},window={label="5 hour",resetsAt=reset_at}},
	},
}}},now_ms)[1].stale,true,"explicit now_ms takes precedence over generatedAt")

local first = usage.scan({generatedAt=now_ms,reports={{
	provider="openai-codex",fetchedAt=reset_at-1000,limits={
		{label="5h",amount={usedFraction=1},window={label="5 hour",resetsAt=reset_at}},
	},
}}})
eq(first[1].stale,true)
local next_scan = usage.scan({generatedAt=now_ms,reports={{
	provider="openai-codex",fetchedAt=now_ms,limits={
		{label="5h",amount={usedFraction=0.4},window={label="5 hour",resetsAt=now_ms+100000}},
	},
}}})
close(next_scan[1].remaining,0.6,"a fresh scan replaces a fully depleted stale scan")
eq(next_scan[1].stale,false)

assert(usage.reset_due({{reset_at=reset_at,fetched_at=reset_at-1}},now_ms))
assert(usage.reset_due({{reset_at=reset_at}},now_ms),"missing fetch timestamp is due after reset")
eq(usage.reset_due({{reset_at=reset_at,fetched_at=reset_at}},now_ms),true,"a report fetched at reset needs a post-reset fetch")
eq(usage.reset_due({{reset_at=now_ms+1000,fetched_at=now_ms}},now_ms),false)
eq(usage.reset_due(restored,now_ms),false)

print("Switchboard usage checks passed")

assert(usage.reset_label(0)=="Resets 1970-01-01 00:00 UTC")
assert(usage.reset_label(1709251200000)=="Resets 2024-03-01 00:00 UTC")

eq(usage.reset_countdown(now_ms+2*60*60*1000+15*60*1000,now_ms),"Resets in 2h 15m")
eq(usage.reset_countdown(now_ms+18*60*1000,now_ms),"Resets in 18m")
eq(usage.reset_countdown(now_ms+24*60*60*1000+3*60*60*1000,now_ms),"Resets in 1d 3h")
eq(usage.reset_countdown(now_ms+30000,now_ms),"Resets in <1m")
eq(usage.reset_countdown(now_ms,now_ms),"Reset due")
eq(usage.reset_countdown("invalid",now_ms),nil)

local identity_latest = usage.scan({generatedAt=now_ms,reports={
	{provider="anthropic",metadata={accountId="redacted-one"},fetchedAt=now_ms-2000,limits={
		{label="5h",amount={usedFraction=1},window={id="5h",label="5 hour",resetsAt=reset_at}},
	}},
	{provider="anthropic",metadata={accountId="redacted-one"},fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=0},window={id="5h",label="5 hour"}},
	}},
}})
eq(#identity_latest,1)
eq(identity_latest[1].remaining,1,"newer same-account report replaces older depletion")
eq(identity_latest[1].stale,false)

local same_timestamp = usage.scan({generatedAt=now_ms,reports={
	{provider="anthropic",metadata={accountId="redacted-one"},fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=0},window={id="5h",label="5 hour"}},
	}},
	{provider="anthropic",metadata={accountId="redacted-one"},fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=1},window={id="5h",label="5 hour"}},
	}},
}})
eq(#same_timestamp,1)
eq(same_timestamp[1].remaining,0,"same-timestamp duplicates keep the conservative depleted value")

local separate_accounts = usage.scan({generatedAt=now_ms,reports={
	{provider="anthropic",metadata={accountId="redacted-one"},fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=1},window={id="5h",label="5 hour",resetsAt=now_ms+100000}},
	}},
	{provider="anthropic",metadata={accountId="redacted-two"},fetchedAt=now_ms-1000,limits={
		{label="5h",amount={usedFraction=0},window={id="5h",label="5 hour",resetsAt=now_ms+100000}},
	}},
}})
eq(#separate_accounts,2,"different OMP account scopes remain distinct")

local reset_boundary = usage.scan({generatedAt=now_ms,reports={{
	provider="anthropic",fetchedAt=reset_at,limits={{
		label="5h",amount={usedFraction=1},window={label="5 hour",resetsAt=reset_at},
	}},
}}})
eq(reset_boundary[1].stale,true,"a report fetched at the reset boundary needs a strictly newer fetch")
assert(usage.reset_due({{reset_at=reset_at,fetched_at=reset_at}},now_ms),"reset boundary should trigger a refresh")
return true
