--!strict

local Profiler = require(script.Parent.Profiler)

local Map = {}

function Map.Generate(overrides: { [string]: any }?): { [string]: any }
	return Profiler.RunMapBench({
		overrides = overrides,
		writeTerrain = true,
	})
end

function Map.Bench(overrides: { [string]: any }?): { [string]: any }
	return Profiler.RunMapBench({
		overrides = overrides,
		writeTerrain = false,
	})
end

function Map.BenchScenarios(): string
	return Profiler.RunScenarioSet()
end

function Map.SceneHealth(): string
	return Profiler.SceneHealth()
end

return Map
