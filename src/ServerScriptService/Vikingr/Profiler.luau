--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local Hash = require(Vikingr.Hash)
local WorldSpec = require(Vikingr.WorldSpec)
local ChunkStore = require(Vikingr.ChunkStore)
local TerrainField = require(Vikingr.TerrainField)
local TerrainWriter = require(script.Parent.TerrainWriter)

local Profiler = {}

local function ms(startTime: number): number
	return math.floor((os.clock() - startTime) * 100000 + 0.5) / 100
end

function Profiler.RunMapBench(options: { [string]: any }?): { [string]: any }
	options = options or {}
	local config = WorldSpec.cloneConfig(options.overrides)

	debug.profilebegin("Vikingr.Bench.build")
	local buildStart = os.clock()
	local state = ChunkStore.build(config)
	local buildMs = ms(buildStart)
	debug.profileend()

	debug.profilebegin("Vikingr.Bench.field")
	local fieldStart = os.clock()
	local fieldState = TerrainField.build(config, state)
	local fieldMs = ms(fieldStart)
	debug.profileend()

	local writeStats = nil
	local writeMs = 0
	if options.writeTerrain ~= false then
		local writeStart = os.clock()
		writeStats = TerrainWriter.write(config, state, fieldState)
		writeMs = ms(writeStart)
	end

	local britainSeconds = WorldSpec.walkSeconds(config, 41)
	local icelandWidthSeconds = WorldSpec.walkSeconds(config, 20)

	return {
		seed = config.seed,
		width = config.width,
		depth = config.depth,
		cellSize = config.cellSize,
		chunkSize = config.chunkSize,
		voxelResolution = config.voxelResolution,
		voxelChunkCells = config.voxelChunkCells,
		buildMs = buildMs,
		fieldMs = fieldMs,
		writeMs = writeMs,
		totalMs = buildMs + fieldMs + writeMs,
		landCells = Hash.countKeys(state.land),
		chunks = Hash.countKeys(state.chunks),
		regions = state.regionCounts,
		features = fieldState.featureCounts,
		regimes = fieldState.regimeCounts,
		altitude = fieldState.altitudeStats,
		water = fieldState.waterStats,
		macro = fieldState.macroStats,
		stages = fieldState.profileStats,
		diagnostics = TerrainField.diagnostics(config, fieldState),
		settlements = fieldState.macroStats.ports,
		routes = fieldState.macroStats.routes,
		walkScale = {
			britainNorthSouthSeconds = math.floor(britainSeconds + 0.5),
			icelandWestEastSeconds = math.floor(icelandWidthSeconds + 0.5),
		},
		writeStats = writeStats,
	}
end

function Profiler.RunScenarioSet(): string
	local scenarios = {
		{ name = "smoke", overrides = { width = 32, depth = 24, cellSize = 48, chunkSize = 8 }, writeTerrain = false },
		{ name = "current", overrides = {}, writeTerrain = false },
		{ name = "iceland-scale", overrides = { width = 48, depth = 36, cellSize = 64, chunkSize = 8 }, writeTerrain = false },
	}

	local results = {}
	for _, scenario in ipairs(scenarios) do
		table.insert(results, {
			name = scenario.name,
			result = Profiler.RunMapBench({
				overrides = scenario.overrides,
				writeTerrain = scenario.writeTerrain,
			}),
		})
	end

	return HttpService:JSONEncode(results)
end

function Profiler.SceneHealth(): string
	local sas = game:GetService("SceneAnalysisService")
	local results = {}
	local queries = {
		{ name = "InstanceComposition", fn = function() return sas:GetInstanceCompositionAsync() end },
		{ name = "TriangleComposition", fn = function() return sas:GetTriangleCompositionAsync() end },
		{ name = "ScriptMemory", fn = function() return sas:GetScriptMemoryAsync() end },
		{ name = "UnparentedInstances", fn = function() return sas:GetUnparentedInstancesAsync() end },
	}

	for _, query in ipairs(queries) do
		local ok, data = pcall(query.fn)
		if ok then
			results[query.name] = data
		else
			results[query.name] = { error = tostring(data) }
		end
	end

	return HttpService:JSONEncode(results)
end

return Profiler
