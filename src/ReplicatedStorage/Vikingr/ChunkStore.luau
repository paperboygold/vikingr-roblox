--!strict
--!native

local Hash = require(script.Parent.Hash)
local WorldSpec = require(script.Parent.WorldSpec)
local ContinentField = require(script.Parent.ContinentField)

local ChunkStore = {}

export type State = {
	land: { [string]: boolean },
	region: { [string]: string },
	height: { [string]: number },
	material: { [string]: Enum.Material },
	adjacency: { [string]: { string } },
	chunks: { [string]: { string } },
	regionCounts: { [string]: number },
	settlements: { [string]: any },
	routes: { [string]: { string } },
}

function ChunkStore.cellKey(x: number, z: number): string
	return Hash.key({ "cell", x, z })
end

function ChunkStore.chunkKey(cx: number, cz: number): string
	return Hash.key({ "chunk", cx, cz })
end

function ChunkStore.parseCellKey(key: string): (number, number)
	local parts = Hash.splitKey(key)
	return tonumber(parts[2]) :: number, tonumber(parts[3]) :: number
end

local function emptyState(): State
	return {
		land = {},
		region = {},
		height = {},
		material = {},
		adjacency = {},
		chunks = {},
		regionCounts = {},
		settlements = {},
		routes = {},
	}
end

-- Structural domain only: mark solid-land cells (from the closed-form ContinentField)
-- and build chunk grouping + 4-neighbour adjacency. Height/material/region/water are
-- emergent and live in the FieldMap (see TerrainField); settlements/routes are emergent
-- (see SiteField). This just gates which chunks the writer voxelizes.
function ChunkStore.build(config: WorldSpec.Config): State
	local state = emptyState()
	local halfW = math.floor(config.width / 2)
	local halfD = math.floor(config.depth / 2)
	local cp = ContinentField.paramsFromSeed(config)

	for x = -halfW, halfW - 1 do
		for z = -halfD, halfD - 1 do
			if ContinentField.continentAt(config, cp, x, z) > 0 then
				local key = ChunkStore.cellKey(x, z)
				local chunkX = math.floor((x + halfW) / config.chunkSize)
				local chunkZ = math.floor((z + halfD) / config.chunkSize)
				local chunkKey = ChunkStore.chunkKey(chunkX, chunkZ)

				Hash.put(Hash.keep, key, true, state.land)
				Hash.put(Hash.count, "land", 1, state.regionCounts)
				Hash.put(Hash.link, chunkKey, { key }, state.chunks)
				Hash.put(Hash.link, key, {
					ChunkStore.cellKey(x + 1, z),
					ChunkStore.cellKey(x - 1, z),
					ChunkStore.cellKey(x, z + 1),
					ChunkStore.cellKey(x, z - 1),
				}, state.adjacency)
			end
		end
	end

	return state
end

return ChunkStore
