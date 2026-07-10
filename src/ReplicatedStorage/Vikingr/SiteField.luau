--!strict
--!native

-- SiteField — emergent settlement + local-generator layer, run last on the converged
-- world. Landmasses are connected components of land; ports are scored coast cells
-- (sheltered, flat-backed, near river mouths); routes are the nearest cross-landmass
-- port pairs — the cross-sea raiding lanes the design requires. CA passes add forest
-- clumps and grow marshes. All of this operates on masks/scalars (no Roblox types).

local WorldSpec = require(script.Parent.WorldSpec)
local Hash = require(script.Parent.Hash)
local FieldMap = require(script.Parent.FieldMap)
local RegimeField = require(script.Parent.RegimeField)

local SiteField = {}

export type Port = { key: FieldMap.CellKey, x: number, z: number, landmass: number, score: number }
export type Route = { a: Port, b: Port, distance: number }
export type State = {
	landmasses: number,
	bigLandmasses: number,
	ports: { Port },
	routes: { Route },
	forestCells: number,
}

local NB8 = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

-- Label connected land components; bake scalar "landmass"; return id→size.
local function labelLandmasses(fm: FieldMap.FieldMap): ({ [FieldMap.CellKey]: number }, { [number]: number })
	local landmass, sizes = FieldMap.componentLabels(fm, "land")
	for key, id in pairs(landmass) do
		FieldMap.setScalar(fm, "landmass", key, id)
	end
	return landmass, sizes
end

local function slopeAt(fm: FieldMap.FieldMap, x: number, z: number): number
	local function e(cx, cz) return FieldMap.getScalar(fm, "elevHydro", FieldMap.cellKey(cx, cz), fm.config.seaLevel) end
	local dx = (e(x + 1, z) - e(x - 1, z)) * 0.5
	local dz = (e(x, z + 1) - e(x, z - 1)) * 0.5
	return math.sqrt(dx * dx + dz * dz)
end

-- Harbor quality: sheltered (partial sea enclosure), flat backshore, river mouth near,
-- not a cliff.
local function portScore(fm: FieldMap.FieldMap, x: number, z: number, key: FieldMap.CellKey): number
	local seaN, riverN = 0, 0
	for _, d in ipairs(NB8) do
		local nk = FieldMap.cellKey(x + d[1], z + d[2])
		if not FieldMap.hasMask(fm, "land", nk) then seaN += 1 end
		if FieldMap.hasMask(fm, "river", nk) then riverN += 1 end
	end
	local shelter = 3 - math.abs(seaN - 3) -- best when ~3 of 8 neighbours are sea
	local flat = math.max(0, 3 - slopeAt(fm, x, z))
	local riverMouth = riverN > 0 and 4 or 0
	return shelter + flat + riverMouth
end

local function buildForest(config: WorldSpec.Config, fm: FieldMap.FieldMap, regime: RegimeField.State)
	local B = WorldSpec.Tuning.biome
	local landKeys = FieldMap.maskKeys(fm, "land")
	-- seed on inland grass/hill with some rainfall
	for _, key in ipairs(landKeys) do
		local r = regime.regime[key]
		if (r == "plain" or r == "hill") and not FieldMap.hasMask(fm, "coast", key) then
			local rain = FieldMap.getScalar(fm, "rainfall", key, 0)
			local x, z = FieldMap.parseKey(key)
			if rain > B.marshRain * 0.6 and WorldSpec.hash01(config.seed + 771, x, z) > 0.55 then
				FieldMap.setMask(fm, "forest", key)
			end
		end
	end
	-- grow clumps: a candidate joins if it has >=3 forest neighbours
	for _ = 1, WorldSpec.Tuning.sites.forestPasses do
		local add: { FieldMap.CellKey } = {}
		for _, key in ipairs(landKeys) do
			if not FieldMap.hasMask(fm, "forest", key) and not FieldMap.hasMask(fm, "coast", key) then
				local r = regime.regime[key]
				if r == "plain" or r == "hill" then
					local x, z = FieldMap.parseKey(key)
					local n = 0
					for _, d in ipairs(NB8) do
						if FieldMap.hasMask(fm, "forest", FieldMap.cellKey(x + d[1], z + d[2])) then n += 1 end
					end
					if n >= 3 then table.insert(add, key) end
				end
			end
		end
		for _, key in ipairs(add) do FieldMap.setMask(fm, "forest", key) end
	end
end

function SiteField.build(config: WorldSpec.Config, fm: FieldMap.FieldMap, regime: RegimeField.State): State
	local T = WorldSpec.Tuning.sites
	local landmass, sizes = labelLandmasses(fm)

	-- ports: score coast cells, keep top-K per big landmass
	local coastByLM: { [number]: { Port } } = {}
	for _, key in ipairs(FieldMap.maskKeys(fm, "coast")) do
		local lm = landmass[key]
		if lm ~= nil and sizes[lm] >= T.minLandmassCells then
			local x, z = FieldMap.parseKey(key)
			coastByLM[lm] = coastByLM[lm] or {}
			table.insert(coastByLM[lm], { key = key, x = x, z = z, landmass = lm, score = portScore(fm, x, z, key) })
		end
	end
	local ports: { Port } = {}
	local portsByLM: { [number]: { Port } } = {}
	for _, list in pairs(coastByLM) do
		local top = Hash.topK(list, T.portsPerLandmass, function(a: Port, b: Port)
			return a.score > b.score
		end)
		for _, port in ipairs(top) do
			table.insert(ports, port)
			portsByLM[port.landmass] = portsByLM[port.landmass] or {}
			table.insert(portsByLM[port.landmass], port)
			FieldMap.setMask(fm, "port", port.key)
		end
	end

	-- routes: nearest port pair between each pair of big landmasses (cross-sea lanes)
	local bigList: { number } = {}
	local bigCount = 0
	for id, size in pairs(sizes) do
		if size >= T.minLandmassCells then
			bigCount += 1
			table.insert(bigList, id)
		end
	end
	table.sort(bigList)
	local routes: { Route } = {}
	for i = 1, #bigList do
		for j = i + 1, #bigList do
			local li, lj = bigList[i], bigList[j]
			local bestA, bestB, bestDsq = Hash.argminPair(portsByLM[li] or {}, portsByLM[lj] or {}, function(a: Port, b: Port): number
				local dx, dz = a.x - b.x, a.z - b.z
				return dx * dx + dz * dz
			end)
			if bestA ~= nil and bestB ~= nil and bestDsq ~= nil then
				table.insert(routes, { a = bestA, b = bestB, distance = math.sqrt(bestDsq) })
			end
		end
	end

	buildForest(config, fm, regime)

	local landmassCount = 0
	for _ in pairs(sizes) do landmassCount += 1 end

	return {
		landmasses = landmassCount,
		bigLandmasses = bigCount,
		ports = ports,
		routes = routes,
		forestCells = FieldMap.countMask(fm, "forest"),
	}
end

return SiteField
