--!strict
-- Bounded memo for view subtrees. An entry is keyed by the card's stable identity
-- and remembers the signature of its inputs: an unchanged signature returns the
-- very node built last time, and changed inputs rebuild in the same slot instead
-- of growing the cache with every new step label.
local M = {}

export type Cache = {
	get: (key: string, signature: string, build: () -> any) -> any,
	clear: () -> (),
	size: () -> number,
	--- Forget which slots rebuilt; call once before building a view.
	begin: () -> (),
	--- Slot keys rebuilt since `begin`, in rebuild order.
	changed: () -> { string },
	--- The node a slot holds now, nil when unknown.
	node: (key: string) -> any,
}

-- One cache belongs to one window and one `ui` builder; nodes carry that builder's
-- node shape, so never share a cache across different UI implementations.
function M.new(limit: number?): Cache
	local entries: { [string]: { signature: string, node: any } } = {}
	local count = 0
	local dirty = {}
	local max = limit or 256
	local cache = {}
	function cache.get(key: string, signature: string, build: () -> any): any
		local hit = entries[key]
		if hit and hit.signature == signature then return hit.node end
		local node = build()
		table.insert(dirty, key)
		if hit then
			entries[key] = { signature = signature, node = node }
		else
			if count >= max then entries, count = {}, 0 end
			entries[key] = { signature = signature, node = node }
			count += 1
		end
		return node
	end
	function cache.clear(): ()
		entries, count = {}, 0
	end
	function cache.size(): number
		return count
	end
	function cache.begin(): ()
		dirty = {}
	end
	function cache.changed(): { string }
		return dirty
	end
	function cache.node(key: string): any
		local hit = entries[key]
		return hit and hit.node
	end
	return cache
end

return M
