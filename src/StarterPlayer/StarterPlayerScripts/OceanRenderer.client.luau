--!strict

-- OceanRenderer (client) — the wave surface, rebased on the universe_live model: the FIELD
-- is fixed in world space and the observer moves THROUGH it (universe_live.rs: "the camera
-- IS the observer... flying in reads the same x=B/U at a finer frame"). The MeshPart is
-- therefore FIXED and only its vertices deform — moving the part per-frame was what stopped
-- the deformation from rendering (only vertex colours kept updating → a foam crest sliding
-- over a flat plane). Ocean.luau advances conservative water-column and horizontal
-- momentum lanes; this mesh reads their free surface and characteristic dissipation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local Ocean = require(Vikingr:WaitForChild("Ocean"))
local WorldSpec = require(Vikingr:WaitForChild("WorldSpec"))

local N, SP = 96, 21 -- 2016 studs, finer shore quantization while keeping startup/mesh cost bounded
local config = WorldSpec.Config
if config.waterRenderer ~= "custom" then
	return
end
local SEA = config.seaLevel
local HALF = N / 2 * SP

local DEEP = Color3.fromRGB(10, 60, 88)
local MID = Color3.fromRGB(28, 120, 158)
local FOAM = Color3.fromRGB(238, 248, 252)

local rayParams = RaycastParams.new()
rayParams.IgnoreWater = true
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { Workspace.Terrain }
local depthCache: { [string]: number } = {}
local function depthAt(wx: number, wz: number): number
	local qx = math.floor(wx + 0.5)
	local qz = math.floor(wz + 0.5)
	local key = qx .. ":" .. qz
	local cached = depthCache[key]
	if cached ~= nil then
		return cached
	end
	local origin = Vector3.new(wx, config.maxHeight + 256, wz)
	local distance = config.maxHeight + config.waterDepth + 512
	local hit = Workspace:Raycast(origin, Vector3.new(0, -distance, 0), rayParams)
	local depth = 0
	if hit ~= nil then
		depth = SEA - hit.Position.Y
		depthCache[key] = depth
	end
	return depth
end

-- fixed patch, centred on where the player spawns (the observer moves through it)
local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")
local cx = math.floor(root.Position.X / SP) * SP
local cz = math.floor(root.Position.Z / SP) * SP

local ocean = Ocean.new({
	N = N, spacing = SP, seaLevel = SEA,
	originX = cx - HALF, originZ = cz - HALF,
	windAngle = 0.5, windStrength = 1.9, depthFn = depthAt,
})
_G.VikingrOcean = ocean

do
	local mn, mx, sum = 1, 0, 0
	for _, e in ipairs(ocean.exposure) do
		mn = math.min(mn, e); mx = math.max(mx, e); sum += e
	end
	print(string.format("[Ocean] exposure at spawn patch: min=%.2f max=%.2f mean=%.2f (spatial variation=%s)",
		mn, mx, sum / #ocean.exposure, tostring(mx - mn > 0.15)))
end

-- edge fade so the patch melts to a flat rim (seamless against the distant flat base)
local BORDER = 9
local fadeArr = {}
for i = 0, N - 1 do
	fadeArr[i] = math.clamp(math.min(i, N - 1 - i) / BORDER, 0, 1)
end

-- horizon haze
local atmos = game:GetService("Lighting"):FindFirstChildOfClass("Atmosphere")
if atmos == nil then
	atmos = Instance.new("Atmosphere")
	atmos.Parent = game:GetService("Lighting")
end
atmos.Density = 0.2
atmos.Haze = 1.4
atmos.Color = Color3.fromRGB(199, 216, 226)
atmos.Decay = Color3.fromRGB(150, 178, 190)

-- build the mesh once (position / normal / colour ids per vertex)
local em = ((game:GetService("AssetService") :: any)):CreateEditableMesh()
local pid, nid, cid = {}, {}, {}
local face1, face2 = {}, {}
for i = 0, N - 1 do
	pid[i], nid[i], cid[i] = {}, {}, {}
	for j = 0, N - 1 do
		pid[i][j] = em:AddVertex(Vector3.new((i - N / 2) * SP, 0, (j - N / 2) * SP))
		nid[i][j] = em:AddNormal(Vector3.yAxis)
		cid[i][j] = em:AddColor(MID, 1)
	end
end

local function addFace1(i: number, j: number): number
	local face = em:AddTriangle(pid[i][j], pid[i][j + 1], pid[i + 1][j])
	em:SetFaceNormals(face, { nid[i][j], nid[i][j + 1], nid[i + 1][j] })
	em:SetFaceColors(face, { cid[i][j], cid[i][j + 1], cid[i + 1][j] })
	return face
end

local function addFace2(i: number, j: number): number
	local face = em:AddTriangle(pid[i][j + 1], pid[i + 1][j + 1], pid[i + 1][j])
	em:SetFaceNormals(face, { nid[i][j + 1], nid[i + 1][j + 1], nid[i + 1][j] })
	em:SetFaceColors(face, { cid[i][j + 1], cid[i + 1][j + 1], cid[i + 1][j] })
	return face
end

local initialWet = ocean.wet
local initialFaceCount = 0
for i = 0, N - 2 do
	face1[i], face2[i] = {}, {}
	for j = 0, N - 2 do
		local c = i * N + j + 1
		if initialWet[c] and initialWet[c + 1] and initialWet[c + N] then
			face1[i][j] = addFace1(i, j)
			initialFaceCount += 1
		end
		if initialWet[c + 1] and initialWet[c + N + 1] and initialWet[c + N] then
			face2[i][j] = addFace2(i, j)
			initialFaceCount += 1
		end
	end
end
local placeholderFace = if initialFaceCount == 0 then addFace1(0, 0) else nil
local surface = ((game:GetService("AssetService") :: any)):CreateMeshPartAsync(Content.fromObject(em))
if placeholderFace ~= nil then
	em:RemoveFace(placeholderFace)
end
surface.Name = "Ocean"
surface.Anchored = true
surface.CanCollide = false
surface.CanQuery = false -- CRITICAL: raycasts respect CanQuery, not CanCollide. Without
	-- this, WaterController's "is there ground under my feet" shore raycast hits the wave
	-- surface itself (the player floats right at it by design) — a near-zero hit distance
	-- misreads as "standing on shore" and fires the undebounced shore-exit constantly,
	-- which is the erratic Freefall/Swimming/GettingUp cycling ("locked up, can't move").
surface.CastShadow = false
surface.Material = Enum.Material.SmoothPlastic
surface.Color = Color3.new(1, 1, 1)
surface.Transparency = 0
surface.Position = Vector3.new(cx, SEA, cz)
surface.Parent = Workspace

-- The field is world-locked; the patch (and its full-amplitude CENTRE) follows the player,
-- so wherever you are in deep water you get full waves (shore stays shoaled/calm). Moving the
-- MeshPart each frame is fine — the deformation still renders (verified).
local clamped = table.create(N * N, 0)
local visible = table.create(N * N, false)
local coverage = table.create(N * N, 0)
local depthRefresh = 0

RunService.Heartbeat:Connect(function(dt)
	ocean:recenter(math.floor(root.Position.X / SP) * SP - HALF, math.floor(root.Position.Z / SP) * SP - HALF, depthAt)
	depthRefresh += dt
	if depthRefresh >= 0.75 then
		depthRefresh = 0
		ocean:setDepth(depthAt)
	end
	surface.Position = Vector3.new(ocean.originX + HALF, SEA, ocean.originZ + HALF)
	ocean:step(math.min(dt, 1 / 30))
	local h, wet, breaking, groundY = ocean.h, ocean.wet, ocean.breaking, ocean.groundY
	local wetCount, dryCount = 0, 0
	local shoreCount = 0
	local breakingCount, maxBreaking = 0, 0
	local runupCells, partialCells, maxRunupGround = 0, 0, SEA

	-- pass 1: wet cells carry the solver's free surface directly. Dry cells that
	-- border water are shoreline boundary vertices: they sit at sea level and fade out,
	-- rather than pulling the first wet triangle offshore into a visible moat.
	for i = 0, N - 1 do
		local rb = i * N
		local fadeI = fadeArr[i]
		for j = 0, N - 1 do
			local c = rb + j + 1
			if wet[c] then wetCount += 1 else dryCount += 1 end
			local hc = h[c] * fadeI * fadeArr[j]
			local gy = groundY[c]
			local gxm = if i > 0 then groundY[c - N] else gy
			local gxp = if i < N - 1 then groundY[c + N] else gy
			local gzm = if j > 0 then groundY[c - 1] else gy
			local gzp = if j < N - 1 then groundY[c + 1] else gy
			local bedRise = math.max(
				math.abs(gy - gxm),
				math.abs(gxp - gy),
				math.abs(gy - gzm),
				math.abs(gzp - gy)
			)
			local H = ocean.water[c]
			coverage[c] = if H > 0 then H / math.max(H, bedRise) else 0
			if wet[c] and gy > SEA then
				runupCells += 1
				maxRunupGround = math.max(maxRunupGround, gy)
			end
			if coverage[c] > 0 and coverage[c] < 1 then
				partialCells += 1
			end
			local shore = not wet[c]
				and ((i > 0 and wet[c - N])
					or (i < N - 1 and wet[c + N])
					or (j > 0 and wet[c - 1])
					or (j < N - 1 and wet[c + 1]))
			if shore then
				shoreCount += 1
				hc = gy - SEA
			elseif not wet[c] then
				hc = gy - SEA
			end
			clamped[c] = hc
			visible[c] = wet[c]
		end
	end

	-- A face exists exactly while all three of its vertices are wet. Mixed faces
	-- are not merely made transparent: removing them prevents interpolation across land.
	for i = 0, N - 2 do
		local rb = i * N
		for j = 0, N - 2 do
			local c = rb + j + 1
			local want1 = wet[c] and wet[c + 1] and wet[c + N]
			local f1 = face1[i][j]
			if want1 and f1 == nil then
				face1[i][j] = addFace1(i, j)
			elseif not want1 and f1 ~= nil then
				em:RemoveFace(f1)
				face1[i][j] = nil
			end
			local want2 = wet[c + 1] and wet[c + N + 1] and wet[c + N]
			local f2 = face2[i][j]
			if want2 and f2 == nil then
				face2[i][j] = addFace2(i, j)
			elseif not want2 and f2 ~= nil then
				em:RemoveFace(f2)
				face2[i][j] = nil
			end
		end
	end

	for i = 0, N - 1 do
		local rb = i * N
		local lx = (i - N / 2) * SP
		for j = 0, N - 1 do
			local c = rb + j + 1
			local hc = clamped[c]
			local hxm = (i > 0 and wet[c - N]) and clamped[c - N] or hc
			local hxp = (i < N - 1 and wet[c + N]) and clamped[c + N] or hc
			local hzm = (j > 0 and wet[c - 1]) and clamped[c - 1] or hc
			local hzp = (j < N - 1 and wet[c + 1]) and clamped[c + 1] or hc
			local dhx = (hxp - hxm) / (2 * SP)
			local dhz = (hzp - hzm) / (2 * SP)
			em:SetPosition(pid[i][j], Vector3.new(lx, hc, (j - N / 2) * SP))
			em:SetNormal(nid[i][j], Vector3.new(-dhx, 1, -dhz).Unit)
			local isVisible = visible[c] == true
			local slope = isVisible and math.sqrt(dhx * dhx + dhz * dhz) or 0
			local base = DEEP:Lerp(MID, math.clamp((hc + 7) / 13, 0, 1))
			local alpha = coverage[c]
			local breaker = wet[c] and (breaking[c] or 0) * fadeArr[i] * fadeArr[j] * alpha or 0
			if breaker > 0 then
				breakingCount += 1
				maxBreaking = math.max(maxBreaking, breaker)
			end
			local foam = math.clamp((hc - 2.2) * 0.42 + slope * 3.2 + breaker * 0.9, 0, 1)
			em:SetColor(cid[i][j], base:Lerp(FOAM, foam))
			em:SetColorAlpha(cid[i][j], 1 - alpha)
		end
	end
	surface:SetAttribute("oceanPeak", ocean:peak())
	surface:SetAttribute("wetCells", wetCount)
	surface:SetAttribute("dryCells", dryCount)
	surface:SetAttribute("shoreCells", shoreCount)
	surface:SetAttribute("breakingCells", breakingCount)
	surface:SetAttribute("maxBreaking", maxBreaking)
	surface:SetAttribute("runupCells", runupCells)
	surface:SetAttribute("partialCoverageCells", partialCells)
	surface:SetAttribute("maxRunupGround", maxRunupGround)
end)
