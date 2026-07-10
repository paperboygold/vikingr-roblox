--!strict

-- BuoyancyDemo (client) — a raft that rides the wave field. Samples ocean height+normal
-- at four hull corners and averages them (so a single steep vertex can't throw it), then
-- eases the pose toward the target each frame (kills jitter). Same field drives visuals
-- and buoyancy. A physics-force version plugs into the same Ocean:heightAt/normalAt.

local RunService = game:GetService("RunService")

while _G.VikingrOcean == nil do
	task.wait()
end
local ocean = _G.VikingrOcean

local raft = Instance.new("Part")
raft.Name = "RaftDemo"
raft.Size = Vector3.new(26, 3, 44)
raft.Anchored = true
raft.CanCollide = false
raft.Material = Enum.Material.WoodPlanks
raft.Color = Color3.fromRGB(101, 67, 41)
raft.Position = Vector3.new(0, 16, 0)
raft.Parent = workspace

local X, Z = 0, 0
local HW, HL = 12, 20 -- half hull footprint
local corners = { { X - HW, Z - HL }, { X + HW, Z - HL }, { X - HW, Z + HL }, { X + HW, Z + HL } }

RunService.Heartbeat:Connect(function(dt)
	local sumH, sumN = 0, Vector3.zero
	for _, c in ipairs(corners) do
		sumH += ocean:heightAt(c[1], c[2])
		sumN += ocean:normalAt(c[1], c[2])
	end
	local h = sumH / 4
	local n = (sumN / 4).Unit
	local fwd = Vector3.new(0, 0, -1)
	local right = fwd:Cross(n)
	if right.Magnitude < 1e-3 then right = Vector3.new(1, 0, 0) end
	local target = CFrame.fromMatrix(Vector3.new(X, h + 1.6, Z), right.Unit, n)
	raft.CFrame = raft.CFrame:Lerp(target, math.clamp(dt * 7, 0, 1))
end)
