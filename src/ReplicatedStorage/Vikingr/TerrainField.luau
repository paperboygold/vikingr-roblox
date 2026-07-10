--!strict
--!native

-- TerrainField — the pipeline orchestrator (build) and the O(1) sampling façade the
-- voxel writer calls. All heavy work happens once in build(); sampleVoxel/sampleHeight/
-- sampleRegion are O(1) baked reads (dict lookups + a 4-cell bilerp).
--
-- Pipeline (each field cached in the FieldMap):
--   1 macro   — ContinentField/ReliefField → land mask, continent, elevRaw, elevHydro
--   2 climate — ClimateField.buildRainfall (rain shadow)
--   3 drainage— Hydrology.solve (priority-flood, D8, flow accumulation, rivers, lakes)
--   4 erosion — Erosion.run then Hydrology.refine (final water on eroded surface)
--   5 biome   — RegimeField.build (collapse on converged fields)
--   6 sites   — SiteField.build (landmasses, ports, cross-sea routes, forests)
--   7 toState — legacy-shaped façade for TerrainWriter + Profiler
--
-- Land AND seabed are both voxelized (real bathymetry from ReliefField's underwater
-- relief, not a flat slab) — only true out-of-bounds queries return nil. The coast-bilerp
-- clamp keeps beaches gentle at the land/sea boundary.

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)
local ContinentField = require(script.Parent.ContinentField)
local ReliefField = require(script.Parent.ReliefField)
local ClimateField = require(script.Parent.ClimateField)
local Hydrology = require(script.Parent.Hydrology)
local Erosion = require(script.Parent.Erosion)
local WaterSim = require(script.Parent.WaterSim)
local RegimeField = require(script.Parent.RegimeField)
local SiteField = require(script.Parent.SiteField)

local TerrainField = {}

export type WaterKind = "sea" | "lake" | "river"

export type State = {
	fm: FieldMap.FieldMap,
	cp: ContinentField.Params,
	rp: ReliefField.Params,
	regime: RegimeField.State,
	sites: SiteField.State,
	featureCounts: { [string]: number },
	regimeCounts: { [string]: number },
	altitudeStats: { [string]: number },
	waterStats: { [string]: number },
	macroStats: { [string]: number },
	profileStats: { [string]: number },
}

local cellKey = FieldMap.cellKey

-- ── sampling helpers ─────────────────────────────────────────────────────────
local function isLand(fm: FieldMap.FieldMap, x: number, z: number): boolean
	return FieldMap.hasMask(fm, "land", cellKey(x, z))
end

local function slopeAt(fm: FieldMap.FieldMap, x: number, z: number): number
	local function e(cx, cz) return FieldMap.getScalar(fm, "elevHydro", cellKey(cx, cz), fm.config.seaLevel) end
	local dx = (e(x + 1, z) - e(x - 1, z)) * 0.5
	local dz = (e(x, z + 1) - e(x, z - 1)) * 0.5
	return math.sqrt(dx * dx + dz * dz)
end

-- Bilinear elevation. When the sampled column is over land, water-side corners are
-- pinned to the waterline so coasts slope gently to the sea instead of diving to the
-- deep seabed (the coast-bilerp clamp).
local function heightAt(state: State, x: number, z: number): number
	local fm = state.fm
	local seaLevel = fm.config.seaLevel
	local cx, cz = math.floor(x + 0.5), math.floor(z + 0.5)
	local centerLand = isLand(fm, cx, cz)
	local x0, z0 = math.floor(x), math.floor(z)
	local fx, fz = x - x0, z - z0
	local function corner(gx: number, gz: number): number
		local key = cellKey(gx, gz)
		if centerLand and not FieldMap.hasMask(fm, "land", key) then
			return seaLevel
		end
		return FieldMap.getScalar(fm, "elevHydro", key, seaLevel)
	end
	local top = WorldSpec.lerp(corner(x0, z0), corner(x0 + 1, z0), fx)
	local bot = WorldSpec.lerp(corner(x0, z0 + 1), corner(x0 + 1, z0 + 1), fx)
	-- No hard seaLevel floor here: carved river channels legitimately drop below sea
	-- at their mouths. The corner-clamp above already keeps coasts from diving to the
	-- deep seabed.
	return WorldSpec.lerp(top, bot, fz)
end

-- Seabed material by depth below sea level: sandy shallows -> sandstone slope -> rock deep.
-- A real, textured floor (ridges/canyons from ReliefField's underwater residual) instead of
-- the old flat -waterDepth slab, so there is something to actually voxelize and explore.
local function seabedMaterialFor(config: WorldSpec.Config, height: number): Enum.Material
	local depth = config.seaLevel - height
	if depth < 10 then
		return Enum.Material.Sand
	elseif depth < 26 then
		return Enum.Material.Sandstone
	end
	return Enum.Material.Rock
end

-- ── public sampling API (unchanged signatures for TerrainWriter/Profiler) ─────
function TerrainField.sampleVoxel(
	config: WorldSpec.Config,
	state: State,
	x: number,
	z: number
): (string?, number, WaterKind?, number, Enum.Material)
	local fm = state.fm
	local cx, cz = math.floor(x + 0.5), math.floor(z + 0.5)
	if not FieldMap.inBounds(fm, cx, cz) then
		return nil, config.seaLevel - config.waterDepth, "sea", config.seaLevel, Enum.Material.Water
	end

	local key = cellKey(cx, cz)
	local onLand = isLand(fm, cx, cz)
	local height = heightAt(state, x, z)
	local waterKind: WaterKind? = nil
	local waterHeight = config.seaLevel

	if onLand then
		-- All inland water comes from the flux sim's baked depth field (channels are
		-- already incised into the terrain, so we do NOT carve at render time). Shorelines
		-- are sub-cell via the bilerp inside WaterSim.sample.
		local surf, flowing = WaterSim.sample(fm, x, z)
		if surf ~= nil then
			waterKind = flowing and "river" or "lake"
			waterHeight = surf
		elseif height <= config.seaLevel then
			waterKind = "sea"
			waterHeight = config.seaLevel
		end
	else
		-- open sea: a real, varying seabed (ReliefField's underwater relief), water fills
		-- the column above it up to sea level
		waterKind = "sea"
		waterHeight = config.seaLevel
	end

	if onLand then
		local regime = state.regime.regime[key]
		local temp = ClimateField.temperatureAt(config, height, cz)
		local material = RegimeField.materialFor(config, regime, height, temp, slopeAt(fm, cx, cz))
		-- WaterSim's bilinear footprint extends beyond the coarse river/lake regime mask.
		-- Every submerged inland sample therefore owns a non-grass bed material directly.
		if waterKind == "river" or waterKind == "lake" then
			material = Enum.Material.Mud
		end
		return (regime or "land"), height, waterKind, waterHeight, material
	end
	return "seabed", height, waterKind, waterHeight, seabedMaterialFor(config, height)
end

function TerrainField.sampleHeight(config: WorldSpec.Config, state: State, x: number, z: number): number
	local fm = state.fm
	local cx, cz = math.floor(x + 0.5), math.floor(z + 0.5)
	if not FieldMap.inBounds(fm, cx, cz) then
		return config.seaLevel - config.waterDepth
	end
	return heightAt(state, x, z)
end

function TerrainField.sampleRegion(config: WorldSpec.Config, state: State, x: number, z: number): string?
	local fm = state.fm
	local cx, cz = math.floor(x + 0.5), math.floor(z + 0.5)
	if not FieldMap.inBounds(fm, cx, cz) then
		return nil
	end
	if isLand(fm, cx, cz) then
		return state.regime.regime[cellKey(cx, cz)] or "land"
	end
	return "seabed"
end

-- ── build ────────────────────────────────────────────────────────────────────
function TerrainField.build(config: WorldSpec.Config, _chunkState: any?): State
	local fm = FieldMap.new(config)
	local cp = ContinentField.paramsFromSeed(config)
	local rp = ReliefField.paramsFromSeed(config)
	local profileStats: { [string]: number } = {}

	local function startStage(): number
		return os.clock()
	end

	local function endStage(name: string, started: number)
		profileStats[name] = math.floor((os.clock() - started) * 100000 + 0.5) / 100
	end

	-- 1) macro fields (closed-form, baked to grid)
	local stage = startStage()
	FieldMap.eachCell(fm, function(key, x, z)
		local C = ContinentField.continentAt(config, cp, x, z)
		FieldMap.setScalar(fm, "continent", key, C)
		if C > 0 then
			FieldMap.setMask(fm, "land", key)
		end
		local e = ReliefField.elevationAt(config, cp, rp, x, z, C)
		FieldMap.setScalar(fm, "elevRaw", key, e)
		FieldMap.setScalar(fm, "elevHydro", key, e)
	end)
	endStage("macro", stage)

	-- 2) climate
	stage = startStage()
	ClimateField.buildRainfall(config, fm)
	endStage("climate", stage)
	-- 3) drainage
	stage = startStage()
	Hydrology.solve(config, fm)
	endStage("hydrologySolve", stage)
	-- 4) erosion + re-route on eroded surface
	stage = startStage()
	Erosion.run(config, fm, WorldSpec.Tuning.erosion.passes)
	endStage("erosion", stage)
	stage = startStage()
	local hydro = Hydrology.refine(config, fm)
	endStage("hydrologyRefine", stage)
	-- 4b) incise channels + shallow-water flux relaxation (opens mouths, flat lakes,
	--     continuous rivers, velocity field). Runs on/after the eroded surface.
	stage = startStage()
	WaterSim.build(config, fm)
	endStage("waterSim", stage)
	-- 5) biome collapse (reads converged fields)
	stage = startStage()
	local regime = RegimeField.build(config, fm)
	endStage("regime", stage)
	-- 6) emergent sites
	stage = startStage()
	local sites = SiteField.build(config, fm, regime)
	endStage("sites", stage)

	stage = startStage()
	local state = TerrainField.toState(config, fm, cp, rp, regime, sites, hydro, profileStats)
	endStage("toState", stage)
	return state
end

-- ── stats façade ─────────────────────────────────────────────────────────────
function TerrainField.toState(
	config: WorldSpec.Config,
	fm: FieldMap.FieldMap,
	cp: ContinentField.Params,
	rp: ReliefField.Params,
	regime: RegimeField.State,
	sites: SiteField.State,
	hydro: { [string]: number },
	profileStats: { [string]: number }?
): State
	local seaLevel = config.seaLevel

	local altitude = FieldMap.reduceMask(fm, "land", {
		min = math.huge,
		max = -math.huge,
		sum = 0,
		above16 = 0,
		above48 = 0,
		above96 = 0,
		count = 0,
	}, function(acc, key, _x, _z)
		local e = FieldMap.getScalar(fm, "elevHydro", key, seaLevel)
		acc.min = math.min(acc.min, e)
		acc.max = math.max(acc.max, e)
		acc.sum += e
		acc.count += 1
		if e > seaLevel + 16 then acc.above16 += 1 end
		if e > seaLevel + 48 then acc.above48 += 1 end
		if e > seaLevel + 96 then acc.above96 += 1 end
		return acc
	end)
	local n = math.max(1, altitude.count)

	local lakeLevels = FieldMap.reduceMask(fm, "lake", {
		min = math.huge,
		max = -math.huge,
	}, function(acc, key, _x, _z)
		local l = FieldMap.getScalar(fm, "waterLevel", key, seaLevel)
		acc.min = math.min(acc.min, l)
		acc.max = math.max(acc.max, l)
		return acc
	end)

	return {
		fm = fm,
		cp = cp,
		rp = rp,
		regime = regime,
		sites = sites,
		altitudeStats = {
			min = altitude.min == math.huge and seaLevel or altitude.min,
			max = altitude.max == -math.huge and seaLevel or altitude.max,
			avg = altitude.sum / n,
			count = altitude.count,
			above16 = altitude.above16,
			above48 = altitude.above48,
			above96 = altitude.above96,
		},
		waterStats = {
			lakeCells = FieldMap.countMask(fm, "lake"),
			riverCells = FieldMap.countMask(fm, "river"),
			seaCells = FieldMap.countMask(fm, "sea"),
			minLevel = lakeLevels.min == math.huge and seaLevel or lakeLevels.min,
			maxLevel = lakeLevels.max == -math.huge and seaLevel or lakeLevels.max,
		},
		featureCounts = {
			coast = FieldMap.countMask(fm, "coast"),
			cliff = regime.counts["cliff"] or 0,
			river = FieldMap.countMask(fm, "river"),
			lake = FieldMap.countMask(fm, "lake"),
			marsh = FieldMap.countMask(fm, "marsh"),
			forest = FieldMap.countMask(fm, "forest"),
			port = FieldMap.countMask(fm, "port"),
		},
		regimeCounts = regime.counts,
		macroStats = {
			landCells = altitude.count,
			landmasses = sites.landmasses,
			bigLandmasses = sites.bigLandmasses,
			ports = #sites.ports,
			routes = #sites.routes,
			lakeBasins = hydro.lakeBasins or 0,
		},
		profileStats = profileStats or {},
	}
end

-- Structural assertions for the Profiler: >=2 continents, wide sea gap, acyclic
-- drainage, flat lakes. One-time O(N) checks over the baked fields.
function TerrainField.diagnostics(config: WorldSpec.Config, state: State): { [string]: any }
	local fm = state.fm
	local cp = state.cp
	local halfW, halfD = fm.halfW, fm.halfD

	-- min sea-gap width (contiguous non-land straddling the channel centreline)
	local minGap = math.huge
	for z = -halfD, halfD - 1 do
		local center = cp.x0 + cp.amp * math.sin(z * cp.omega + cp.phi)
		local cx = math.clamp(math.floor(center + 0.5), -halfW, halfW - 1)
		if isLand(fm, cx, z) then
			minGap = 0
			break
		end
		local gap, l, r = 1, cx - 1, cx + 1
		while l >= -halfW and not isLand(fm, l, z) do gap += 1; l -= 1 end
		while r <= halfW - 1 and not isLand(fm, r, z) do gap += 1; r += 1 end
		minGap = math.min(minGap, gap)
	end
	minGap = minGap == math.huge and 0 or minGap

	-- drainage acyclic: every land cell reaches a sink via the receiver chain
	local receiver = fm.graph["receiver"] or {}
	local landKeys = FieldMap.maskKeys(fm, "land")
	local maxSteps = #landKeys + 5
	local acyclic = true
	for _, key in ipairs(landKeys) do
		local cur, steps = key, 0
		while receiver[cur] ~= nil do
			cur = receiver[cur][1]
			steps += 1
			if steps > maxSteps then
				acyclic = false
				break
			end
		end
		if not acyclic then break end
	end

	-- lake spill variance (should be ~0: flat lakes)
	local basinMM: { [number]: { min: number, max: number } } = {}
	for _, key in ipairs(FieldMap.maskKeys(fm, "lake")) do
		local b = FieldMap.getScalar(fm, "basin", key, 0)
		local l = FieldMap.getScalar(fm, "waterLevel", key, 0)
		local mm = basinMM[b]
		if mm == nil then
			basinMM[b] = { min = l, max = l }
		else
			mm.min = math.min(mm.min, l)
			mm.max = math.max(mm.max, l)
		end
	end
	local spill = 0
	for _, mm in pairs(basinMM) do
		spill = math.max(spill, mm.max - mm.min)
	end

	local seaGapOk = minGap >= 2 * cp.wsea
	local continentsOk = state.sites.bigLandmasses >= 2
	return {
		continentCount = state.sites.bigLandmasses,
		seaGapWidthCells = minGap,
		seaGapWidthStuds = minGap * config.cellSize,
		drainageAcyclic = acyclic,
		lakeSpillVariance = spill,
		passedContinents = continentsOk,
		passedSeaGap = seaGapOk,
		passedDrainage = acyclic,
		passedFlatLakes = spill < 1e-6,
		allPassed = continentsOk and seaGapOk and acyclic and spill < 1e-6,
	}
end

return TerrainField
