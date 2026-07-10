--!strict
--!native

-- RegimeField — biome collapse, run LAST on the converged fields (seed + fold: each
-- cell reads its settled local boundary — neighbour regimes already chosen + the baked
-- relief/climate/drainage — and collapses to a regime). This replaces the old version
-- that collapsed on raw noise BEFORE elevation existed.
--
--   river / lake        : taken directly from Hydrology masks (forced)
--   strand / cliff       : coast mask + slope
--   wetland (marsh)      : high rainfall + flat + near sea
--   plain / hill / ridge : slope + elevation
--
-- Entropy-ordered WFC with neighbour-adjacency bonuses (unchanged machinery).

local WorldSpec = require(script.Parent.WorldSpec)
local Hash = require(script.Parent.Hash)
local FieldMap = require(script.Parent.FieldMap)

local RegimeField = {}

export type Regime = "strand" | "wetland" | "plain" | "hill" | "ridge" | "cliff" | "river" | "lake"

export type State = {
	regime: { [FieldMap.CellKey]: Regime },
	counts: { [string]: number },
}

local function elev(fm: FieldMap.FieldMap, x: number, z: number): number
	return FieldMap.getScalar(fm, "elevHydro", FieldMap.cellKey(x, z), fm.config.seaLevel)
end

-- slope magnitude in studs of elevation per 1 cell of horizontal step
local function slopeAt(fm: FieldMap.FieldMap, x: number, z: number): number
	local dx = (elev(fm, x + 1, z) - elev(fm, x - 1, z)) * 0.5
	local dz = (elev(fm, x, z + 1) - elev(fm, x, z - 1)) * 0.5
	return math.sqrt(dx * dx + dz * dz)
end

local function candidatesForFacts(
	fm: FieldMap.FieldMap,
	key: FieldMap.CellKey,
	elevation: number,
	slope: number,
	rain: number,
	coast: boolean
): { Regime }
	if FieldMap.hasMask(fm, "lake", key) then
		return { "lake" }
	end
	if FieldMap.hasMask(fm, "river", key) then
		return { "river" }
	end

	local B = WorldSpec.Tuning.biome
	local seaLevel = fm.config.seaLevel

	local out: { Regime } = {}
	if coast then
		table.insert(out, "strand")
		if slope > B.cliffSlope then
			table.insert(out, "cliff")
		end
	end
	if rain > B.marshRain and slope < B.flatSlope and elevation < seaLevel + B.marshBand then
		table.insert(out, "wetland")
	end
	table.insert(out, "plain")
	if slope > B.hillSlope or elevation > seaLevel + B.hillElev then
		table.insert(out, "hill")
	end
	if elevation > seaLevel + B.ridgeElev and slope > B.ridgeSlope then
		table.insert(out, "ridge")
	end
	return out
end

local function candidateWeightFacts(eRel: number, slope: number, rain: number, coast: boolean, regime: Regime): number
	local B = WorldSpec.Tuning.biome

	if regime == "river" or regime == "lake" then
		return 100
	elseif regime == "strand" then
		return coast and 8 or -10
	elseif regime == "cliff" then
		return (coast and slope > B.cliffSlope) and (6 + slope) or -20
	elseif regime == "wetland" then
		return rain * 40 + (B.flatSlope - slope) * 2 + (B.marshBand - eRel) * 0.2
	elseif regime == "plain" then
		return 5 - slope * 1.5
	elseif regime == "hill" then
		return 3 + slope * 1.2 + eRel * 0.02
	elseif regime == "ridge" then
		return eRel * 0.05 + slope * 1.5
	end
	return 0
end

local function adjacencyScore(left: Regime, right: Regime): number
	if left == right then
		return 2.0
	elseif left == "strand" and (right == "wetland" or right == "plain" or right == "cliff") then
		return 1.4
	elseif left == "wetland" and (right == "strand" or right == "river" or right == "lake" or right == "plain") then
		return 1.1
	elseif left == "plain" and (right == "wetland" or right == "hill" or right == "river" or right == "strand") then
		return 1.0
	elseif left == "hill" and (right == "plain" or right == "ridge") then
		return 1.2
	elseif left == "ridge" and right == "hill" then
		return 1.4
	elseif left == "river" and (right == "wetland" or right == "plain" or right == "lake") then
		return 1.3
	elseif left == "lake" and (right == "wetland" or right == "river" or right == "plain") then
		return 1.2
	elseif left == "ridge" and (right == "strand" or right == "lake") then
		return -2.0
	elseif left == "cliff" and (right == "lake" or right == "wetland") then
		return -1.5
	end
	return 0
end

function RegimeField.build(config: WorldSpec.Config, fm: FieldMap.FieldMap): State
	local state: State = { regime = {}, counts = {} }

	-- entropy-ordered frontier (fewest candidates first)
	local frontier: {
		{
			key: FieldMap.CellKey,
			x: number,
			z: number,
			cands: { Regime },
			entropy: number,
			tie: number,
			eRel: number,
			slope: number,
			rain: number,
			coast: boolean,
			east: FieldMap.CellKey,
			west: FieldMap.CellKey,
			north: FieldMap.CellKey,
			south: FieldMap.CellKey,
		}
	} = {}
	local seaLevel = config.seaLevel
	for _, key in ipairs(FieldMap.maskKeys(fm, "land")) do
		local x, z = FieldMap.parseKey(key)
		local e = elev(fm, x, z)
		local s = slopeAt(fm, x, z)
		local rain = FieldMap.getScalar(fm, "rainfall", key, 0)
		local coast = FieldMap.hasMask(fm, "coast", key)
		local cands = candidatesForFacts(fm, key, e, s, rain, coast)
		table.insert(frontier, {
			key = key,
			x = x,
			z = z,
			cands = cands,
			entropy = #cands,
			tie = WorldSpec.hash01(config.seed + 5101, x, z),
			eRel = e - seaLevel,
			slope = s,
			rain = rain,
			coast = coast,
			east = if FieldMap.inBounds(fm, x + 1, z) then FieldMap.cellKey(x + 1, z) else 0,
			west = if FieldMap.inBounds(fm, x - 1, z) then FieldMap.cellKey(x - 1, z) else 0,
			north = if FieldMap.inBounds(fm, x, z + 1) then FieldMap.cellKey(x, z + 1) else 0,
			south = if FieldMap.inBounds(fm, x, z - 1) then FieldMap.cellKey(x, z - 1) else 0,
		})
	end
	table.sort(frontier, function(a, b)
		if a.entropy == b.entropy then
			return a.tie < b.tie
		end
		return a.entropy < b.entropy
	end)

	for _, item in ipairs(frontier) do
		local best = Hash.maxBy(item.cands, function(cand: Regime): number
			local score = candidateWeightFacts(item.eRel, item.slope, item.rain, item.coast, cand)
			score += WorldSpec.hash01(config.seed + 3200, item.x, item.z) * 0.05
			local eastRegime = state.regime[item.east]
			if eastRegime ~= nil then
				score += adjacencyScore(cand, eastRegime)
			end
			local westRegime = state.regime[item.west]
			if westRegime ~= nil then
				score += adjacencyScore(cand, westRegime)
			end
			local northRegime = state.regime[item.north]
			if northRegime ~= nil then
				score += adjacencyScore(cand, northRegime)
			end
			local southRegime = state.regime[item.south]
			if southRegime ~= nil then
				score += adjacencyScore(cand, southRegime)
			end
			return score
		end) or item.cands[1]
		state.regime[item.key] = best
		state.counts[best] = (state.counts[best] or 0) + 1
		if best == "wetland" then
			FieldMap.setMask(fm, "marsh", item.key)
		end
	end

	return state
end

-- Material selection at voxel time (Enum referenced only inside the function body so
-- the module still loads outside Roblox). Reads biome + elevation + temperature.
function RegimeField.materialFor(
	config: WorldSpec.Config,
	regime: Regime?,
	elevation: number,
	temperature: number,
	slope: number
): Enum.Material
	local B = WorldSpec.Tuning.biome
	if regime == "strand" then
		return Enum.Material.Sand
	elseif regime == "river" or regime == "lake" then
		return Enum.Material.Mud
	elseif regime == "wetland" then
		return Enum.Material.LeafyGrass
	elseif regime == "cliff" then
		return Enum.Material.Rock
	end

	if temperature < WorldSpec.Tuning.climate.snowTemp or elevation > config.seaLevel + B.snowElev then
		return Enum.Material.Snow
	end
	if regime == "ridge" then
		return Enum.Material.Rock
	end
	if slope > B.cliffSlope then
		return Enum.Material.Rock
	end
	if regime == "hill" then
		return Enum.Material.Ground
	end
	return Enum.Material.Grass
end

return RegimeField
