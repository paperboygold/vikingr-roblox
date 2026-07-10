--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local Profiler = require(game.ServerScriptService.Vikingr.Profiler)

local function writeValue(name: string, value: string)
	local existing = Vikingr:FindFirstChild(name)
	if not existing then
		existing = Instance.new("StringValue")
		existing.Name = name
		existing.Parent = Vikingr
	end
	(existing :: StringValue).Value = value
end

-- Startup is no-work by default. Full generation is an explicit Studio/edit action via
-- Map.Generate() or Workspace.VikingrGenerateOnBoot = true. Set VikingrBenchOnBoot = true
-- only when you intentionally want the expensive no-write generation benchmark on Play.
local generateAttr = workspace:GetAttribute("VikingrGenerateOnBoot")
local benchAttr = workspace:GetAttribute("VikingrBenchOnBoot")
local writeTerrain = generateAttr == true
local ok = true
local result: any = {
	skipped = true,
	writeTerrain = false,
	bench = false,
	reason = "Set Workspace.VikingrGenerateOnBoot or Workspace.VikingrBenchOnBoot to true to run generation on Play.",
}

if writeTerrain or benchAttr == true then
	ok, result = pcall(function()
		return Profiler.RunMapBench({
			writeTerrain = writeTerrain,
		})
	end)
end

workspace:SetAttribute("VikingrBootstrapRan", true)
workspace:SetAttribute("VikingrBootstrapOk", ok)
workspace:SetAttribute("VikingrBootstrapWriteTerrain", writeTerrain)
workspace:SetAttribute("VikingrBootstrapBench", benchAttr == true)

if ok then
	writeValue("LastBenchStats", HttpService:JSONEncode(result))
else
	writeValue("LastBenchError", tostring(result))
end
