--!strict
--!native

-- FieldMap — the single numeric-coordinate substrate the terrain pipeline writes into.
--
-- One substrate, four faces (see ../sanguine/theory/THE_HASHMAP_PATH.md and Hash.luau):
--   scalar : B    (Hash.setv, last-write)      elevation, uplift, rainfall, waterLevel, ...
--   mask   : NB   (Hash.keep, idempotent-or)   land, sea, coast, river, lake, ...
--   accum  : B/U  (Hash.count, additive)       flowAcc, sedimentFlux  -- order-free / streamable
--   graph  : link (Hash.link, adjacency)       D8 receivers, basin donors, port routes
--
-- The additive `accum` face is the only order-free one (Collapse.lean streaming law):
-- flow accumulation folded high->low over the D8 DAG is exact regardless of chunking.
--
-- snapshot/commit is the substrate form of song's schedule-free Web.sweep: read from a
-- frozen snapshot, write a fresh buffer, commit atomically -- so a relaxation/erosion pass
-- never sees its own half-applied updates.

local Hash = require(script.Parent.Hash)
local WorldSpec = require(script.Parent.WorldSpec)

local FieldMap = {}
local activeHalfW = math.floor(WorldSpec.Config.width / 2)
local activeHalfD = math.floor(WorldSpec.Config.depth / 2)
local activeDepth = activeHalfD * 2

export type FieldMap = {
	config: WorldSpec.Config,
	halfW: number,
	halfD: number,
	topology: Topology,
	scalar: { [string]: { [number]: number } },
	mask: { [string]: { [number]: boolean } },
	accum: { [string]: { [number]: number } },
	graph: { [string]: { [number]: { number } } },
}

export type CellKey = number
export type Topology = {
	count: number,
	-- Eight oriented face/diagonal slots per cell: E, W, N, S, NE, SE, NW, SW.
	-- Slot value 0 is the exterior Null seam, so no invalid dense key is constructed.
	neighbors8: { number },
}

local cachedTopologyWidth = 0
local cachedTopologyDepth = 0
local cachedTopology: Topology? = nil

local function topologyFor(width: number, depth: number): Topology
	if cachedTopology ~= nil and cachedTopologyWidth == width and cachedTopologyDepth == depth then
		return cachedTopology
	end

	local count = width * depth
	local neighbors8: { number } = table.create(count * 8, 0)
	for xi = 0, width - 1 do
		for zi = 0, depth - 1 do
			local key = xi * depth + zi + 1
			local base = (key - 1) * 8
			local hasE = xi < width - 1
			local hasW = xi > 0
			local hasN = zi < depth - 1
			local hasS = zi > 0
			neighbors8[base + 1] = if hasE then key + depth else 0
			neighbors8[base + 2] = if hasW then key - depth else 0
			neighbors8[base + 3] = if hasN then key + 1 else 0
			neighbors8[base + 4] = if hasS then key - 1 else 0
			neighbors8[base + 5] = if hasE and hasN then key + depth + 1 else 0
			neighbors8[base + 6] = if hasE and hasS then key + depth - 1 else 0
			neighbors8[base + 7] = if hasW and hasN then key - depth + 1 else 0
			neighbors8[base + 8] = if hasW and hasS then key - depth - 1 else 0
		end
	end

	local topology = {
		count = count,
		neighbors8 = neighbors8,
	}
	cachedTopologyWidth = width
	cachedTopologyDepth = depth
	cachedTopology = topology
	return topology
end

-- ── keys ───────────────────────────────────────────────────────────────────
-- Dense bounded numeric coordinate for the active FieldMap build. This removes
-- string concat/split and lets Luau carry the hot field tables on small integers.
function FieldMap.cellKey(x: number, z: number): CellKey
	return (x + activeHalfW) * activeDepth + (z + activeHalfD) + 1
end

function FieldMap.parseKey(key: CellKey | string): (number, number)
	if typeof(key) == "number" then
		local n = (key :: number) - 1
		local q = math.floor(n / activeDepth)
		local r = n - q * activeDepth
		return q - activeHalfW, r - activeHalfD
	end
	local parts = Hash.splitKey(key :: string)
	return tonumber(parts[2]) :: number, tonumber(parts[3]) :: number
end

function FieldMap.new(config: WorldSpec.Config): FieldMap
	activeHalfW = math.floor(config.width / 2)
	activeHalfD = math.floor(config.depth / 2)
	activeDepth = activeHalfD * 2
	return {
		config = config,
		halfW = math.floor(config.width / 2),
		halfD = math.floor(config.depth / 2),
		topology = topologyFor(config.width, config.depth),
		scalar = {},
		mask = {},
		accum = {},
		graph = {},
	}
end

function FieldMap.inBounds(fm: FieldMap, x: number, z: number): boolean
	return x >= -fm.halfW and x <= fm.halfW - 1 and z >= -fm.halfD and z <= fm.halfD - 1
end

-- ── B face (scalar / setv) ──────────────────────────────────────────────────
local function scalarDict(fm: FieldMap, field: string): { [number]: number }
	local dict = fm.scalar[field]
	if dict == nil then
		dict = {}
		fm.scalar[field] = dict
	end
	return dict
end

function FieldMap.setScalar(fm: FieldMap, field: string, key: CellKey, value: number)
	Hash.put(Hash.setv, key, value, scalarDict(fm, field))
end

function FieldMap.getScalar(fm: FieldMap, field: string, key: CellKey, default: number): number
	local dict = fm.scalar[field]
	if dict == nil then
		return default
	end
	local value = dict[key]
	if value == nil then
		return default
	end
	return value
end

function FieldMap.scalarField(fm: FieldMap, field: string): { [number]: number }
	return scalarDict(fm, field)
end

function FieldMap.bilerpScalar(fm: FieldMap, field: string, x: number, z: number, default: number): number
	local x0, z0 = math.floor(x), math.floor(z)
	local fx, fz = x - x0, z - z0
	local function sample(cx: number, cz: number): number
		return FieldMap.getScalar(fm, field, FieldMap.cellKey(cx, cz), default)
	end
	local top = WorldSpec.lerp(sample(x0, z0), sample(x0 + 1, z0), fx)
	local bot = WorldSpec.lerp(sample(x0, z0 + 1), sample(x0 + 1, z0 + 1), fx)
	return WorldSpec.lerp(top, bot, fz)
end

-- ── NB face (mask / keep) ───────────────────────────────────────────────────
local function maskDict(fm: FieldMap, field: string): { [number]: boolean }
	local dict = fm.mask[field]
	if dict == nil then
		dict = {}
		fm.mask[field] = dict
	end
	return dict
end

function FieldMap.setMask(fm: FieldMap, field: string, key: CellKey)
	Hash.put(Hash.keep, key, true, maskDict(fm, field))
end

function FieldMap.clearMask(fm: FieldMap, field: string, key: CellKey)
	local dict = fm.mask[field]
	if dict ~= nil then
		dict[key] = nil
	end
end

function FieldMap.hasMask(fm: FieldMap, field: string, key: CellKey): boolean
	local dict = fm.mask[field]
	return dict ~= nil and dict[key] == true
end

function FieldMap.maskField(fm: FieldMap, field: string): { [number]: boolean }
	return maskDict(fm, field)
end

-- ── B/U face (accum / count) — order-free additive ──────────────────────────
local function accumDict(fm: FieldMap, field: string): { [number]: number }
	local dict = fm.accum[field]
	if dict == nil then
		dict = {}
		fm.accum[field] = dict
	end
	return dict
end

function FieldMap.addCount(fm: FieldMap, field: string, key: CellKey, amount: number)
	Hash.put(Hash.count, key, amount, accumDict(fm, field))
end

function FieldMap.getCount(fm: FieldMap, field: string, key: CellKey): number
	local dict = fm.accum[field]
	if dict == nil then
		return 0
	end
	return dict[key] or 0
end

function FieldMap.accumField(fm: FieldMap, field: string): { [number]: number }
	return accumDict(fm, field)
end

-- ── graph face (link / adjacency) ───────────────────────────────────────────
local function graphDict(fm: FieldMap, field: string): { [number]: { number } }
	local dict = fm.graph[field]
	if dict == nil then
		dict = {}
		fm.graph[field] = dict
	end
	return dict
end

function FieldMap.link(fm: FieldMap, field: string, key: CellKey, targets: { CellKey })
	Hash.put(Hash.link, key, targets, graphDict(fm, field))
end

function FieldMap.neighbors(fm: FieldMap, field: string, key: CellKey): { CellKey }
	local dict = fm.graph[field]
	if dict == nil then
		return {}
	end
	return dict[key] or {}
end

-- ── double buffer (the schedule-free sweep) ─────────────────────────────────
-- Snapshot a scalar field to a plain {key->number} you can read while writing a
-- fresh buffer; commit swaps the buffer in atomically.
function FieldMap.snapshot(fm: FieldMap, field: string): { [number]: number }
	return Hash.cloneMap(scalarDict(fm, field))
end

function FieldMap.commit(fm: FieldMap, field: string, buffer: { [number]: number })
	fm.scalar[field] = buffer
end

-- ── iteration ───────────────────────────────────────────────────────────────
-- Every integer grid cell (the full domain), in a fixed x-major order.
function FieldMap.eachCell(fm: FieldMap, fn: (key: CellKey, x: number, z: number) -> ())
	for x = -fm.halfW, fm.halfW - 1 do
		for z = -fm.halfD, fm.halfD - 1 do
			fn(FieldMap.cellKey(x, z), x, z)
		end
	end
end

-- Only the cells present in a mask field.
function FieldMap.eachMask(fm: FieldMap, field: string, fn: (key: CellKey, x: number, z: number) -> ())
	local dict = fm.mask[field]
	if dict == nil then
		return
	end
	Hash.iterDict(dict, nil, function(_, key, _value)
		local x, z = FieldMap.parseKey(key)
		fn(key, x, z)
		return nil
	end)
end

-- Collect the keys of a mask field into an array (for sorting, counting, ...).
function FieldMap.maskKeys(fm: FieldMap, field: string): { CellKey }
	local out: { CellKey } = {}
	local dict = fm.mask[field]
	if dict ~= nil then
		Hash.iterDict(dict, nil, function(_, key, _value)
			table.insert(out, key)
			return nil
		end)
	end
	return out
end

function FieldMap.countMask(fm: FieldMap, field: string): number
	local dict = fm.mask[field]
	if dict == nil then
		return 0
	end
	return Hash.countKeys(dict)
end

function FieldMap.reduceMask<A>(
	fm: FieldMap,
	field: string,
	acc: A,
	fn: (A, CellKey, number, number) -> A
): A
	local dict = fm.mask[field]
	if dict == nil then
		return acc
	end
	return Hash.iterDict(dict, acc, function(nextAcc, key, _value)
		local x, z = FieldMap.parseKey(key)
		return fn(nextAcc, key, x, z)
	end)
end

function FieldMap.sortedMask(fm: FieldMap, field: string, less: ((CellKey, CellKey) -> boolean)?): { CellKey }
	local keys = FieldMap.maskKeys(fm, field)
	if less ~= nil then
		table.sort(keys, less)
	else
		table.sort(keys)
	end
	return keys
end

function FieldMap.componentLabels(
	fm: FieldMap,
	field: string,
	neighbors: ((CellKey, number, number) -> { CellKey })?
): ({ [CellKey]: number }, { [number]: number })
	local labels: { [CellKey]: number } = {}
	local sizes: { [number]: number } = {}
	local id = 0
	local mask = fm.mask[field]
	if mask == nil then
		return labels, sizes
	end

	local topology = fm.topology
	local basis = topology.neighbors8
	for key = 1, topology.count do
		if mask[key] == true and labels[key] == nil then
			id += 1
			local size = 0
			local stack: { CellKey } = { key }
			local stackN = 1
			labels[key] = id
			while stackN > 0 do
				local current = stack[stackN]
				stack[stackN] = nil
				stackN -= 1
				size += 1
				if neighbors ~= nil then
					local x, z = FieldMap.parseKey(current)
					for _, nextKey in ipairs(neighbors(current, x, z)) do
						if mask[nextKey] == true and labels[nextKey] == nil then
							labels[nextKey] = id
							stackN += 1
							stack[stackN] = nextKey
						end
					end
				else
					local base = (current - 1) * 8
					for slot = base + 1, base + 4 do
						local nextKey = basis[slot]
						if nextKey ~= 0 and mask[nextKey] == true and labels[nextKey] == nil then
							labels[nextKey] = id
							stackN += 1
							stack[stackN] = nextKey
						end
					end
				end
			end
			sizes[id] = size
		end
	end

	return labels, sizes
end

return FieldMap
