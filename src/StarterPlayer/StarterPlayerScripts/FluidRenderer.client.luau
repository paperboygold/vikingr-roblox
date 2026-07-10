--!strict

-- FluidRenderer (client) — a continuous spring so the n-body fluid is always visibly
-- flowing (not a pile of settled orbs). A source above the terrain near the player emits
-- water; particles that drain away (reach the sea or wander off) recycle back to the
-- source, giving a steady stream that runs downhill over the real terrain and pools.
-- Rendered as pooled spheres (raw n-body view); NEVER touches the camera.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local FluidSim = require(Vikingr:WaitForChild("FluidSim"))
local WorldSpec = require(Vikingr:WaitForChild("WorldSpec"))

local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")

local config = WorldSpec.Config
local SEA = config.seaLevel
local FLOOR = SEA - config.waterDepth -- lowest sane rest level (sea floor)

local rayParams = RaycastParams.new()
rayParams.IgnoreWater = true
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }
local groundCache: { [string]: number } = {}
local function groundAt(wx: number, wz: number): number
	local qx = math.floor(wx + 0.5)
	local qz = math.floor(wz + 0.5)
	local key = qx .. ":" .. qz
	local cached = groundCache[key]
	if cached ~= nil then
		return cached
	end
	local origin = Vector3.new(wx, config.maxHeight + 256, wz)
	local distance = config.maxHeight + config.waterDepth + 512
	local hit = workspace:Raycast(origin, Vector3.new(0, -distance, 0), rayParams)
	local g = if hit ~= nil then hit.Position.Y else FLOOR
	if g < FLOOR then g = FLOOR end
	groundCache[key] = g
	return g
end

local SP = 3.0
local N = 800
local fluid = FluidSim.new({ h = 6, solverIters = 4, gravity = -60, epsRelax = 0.1, xsph = 0.05, capacity = N })

-- source: above the terrain a short way uphill from the player (so it runs downhill)
local sx = root.Position.X
local sz = root.Position.Z
local sy = groundAt(sx, sz) + 35

-- prefill all particles at the source so density calibrates, then let them flow
for i = 1, N do
	fluid:spawn(sx + (math.random() - 0.5) * 12, sy + math.random() * 20, sz + (math.random() - 0.5) * 12)
end
fluid.rho0 = fluid:measureDensity()

local folder = Instance.new("Folder")
folder.Name = "FluidParticles"
folder.Parent = workspace
local parts = {}
for i = 1, fluid.n do
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(SP * 1.9, SP * 1.9, SP * 1.9)
	p.Anchored = true; p.CanCollide = false; p.CanQuery = false; p.CastShadow = false
	p.Material = Enum.Material.Glass
	p.Color = Color3.fromRGB(28, 108, 168)
	p.Transparency = 0.2
	p.Parent = folder
	parts[i] = p
end

RunService.Heartbeat:Connect(function(dt)
	fluid:step(math.min(dt, 1 / 60), groundAt)
	local px, py, pz = fluid.px, fluid.py, fluid.pz
	local vx, vy, vz = fluid.vx, fluid.vy, fluid.vz
	for i = 1, fluid.n do
		-- recycle drained/stray water back to the spring for a continuous stream
		local dx, dz = px[i] - sx, pz[i] - sz
		if py[i] <= FLOOR + 1 or (dx * dx + dz * dz) > 500 * 500 then
			px[i] = sx + (math.random() - 0.5) * 10
			py[i] = sy + math.random() * 16
			pz[i] = sz + (math.random() - 0.5) * 10
			vx[i], vy[i], vz[i] = 0, 0, 0
		end
		parts[i].Position = Vector3.new(px[i], py[i], pz[i])
	end
end)
