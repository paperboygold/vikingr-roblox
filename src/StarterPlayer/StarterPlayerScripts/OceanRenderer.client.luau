--!strict

-- OceanRenderer (client) -- render the conservative ocean field without turning its
-- wet/dry seam into a one-cell mask. Mixed solver triangles are clipped at H = 0, so
-- the visible shoreline is the reconstructed free-surface/terrain intersection.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local Ocean = require(Vikingr:WaitForChild("Ocean"))
local WorldSpec = require(Vikingr:WaitForChild("WorldSpec"))

local N, SP = 96, 21
local config = WorldSpec.Config
local SEA = config.seaLevel
local HALF = N / 2 * SP
local CLIP_EPS = 1e-4

local DEEP = Color3.fromRGB(10, 60, 88)
local MID = Color3.fromRGB(28, 120, 158)
local FOAM = Color3.fromRGB(238, 248, 252)

type Vertex = { position: number, normal: number, color: number }
type Edge = { vertex: Vertex? }
type FaceSlot = { face: number?, a: number?, b: number?, c: number? }
type TriangleState = { first: FaceSlot, second: FaceSlot }

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

local player = Players.LocalPlayer
local char = player.Character or player.CharacterAdded:Wait()
local root = char:WaitForChild("HumanoidRootPart")
local cx = math.floor(root.Position.X / SP) * SP
local cz = math.floor(root.Position.Z / SP) * SP

local ocean = Ocean.new({
	N = N,
	spacing = SP,
	seaLevel = SEA,
	originX = cx - HALF,
	originZ = cz - HALF,
	windAngle = 0.5,
	windStrength = 1.9,
	referenceDepth = config.waterDepth,
	depthFn = depthAt,
})
_G.VikingrOcean = ocean

-- Fade only the displacement at the travelling-patch rim. It is never used to decide
-- whether a cell is wet, because that decision belongs to the conservative state.
local BORDER = 9
local fadeArr = {}
for i = 0, N - 1 do
	fadeArr[i] = math.clamp(math.min(i, N - 1 - i) / BORDER, 0, 1)
end

local atmos = game:GetService("Lighting"):FindFirstChildOfClass("Atmosphere")
if atmos == nil then
	atmos = Instance.new("Atmosphere")
	atmos.Parent = game:GetService("Lighting")
end
atmos.Density = 0.2
atmos.Haze = 1.4
atmos.Color = Color3.fromRGB(199, 216, 226)
atmos.Decay = Color3.fromRGB(150, 178, 190)

local em = ((game:GetService("AssetService") :: any)):CreateEditableMesh()
local function newVertex(position: Vector3): Vertex
	return {
		position = em:AddVertex(position),
		normal = em:AddNormal(Vector3.yAxis),
		color = em:AddColor(MID, 0),
	}
end

local grid, vertexAt = {}, table.create(N * N)
local localX, localZ = table.create(N * N), table.create(N * N)
for i = 0, N - 1 do
	grid[i] = {}
	for j = 0, N - 1 do
		local c = i * N + j + 1
		local x = (i - N / 2) * SP
		local z = (j - N / 2) * SP
		local vertex = newVertex(Vector3.new(x, 0, z))
		grid[i][j] = vertex
		vertexAt[c] = vertex
		localX[c], localZ[c] = x, z
	end
end

-- Edges acquire a render vertex only once they actually contain the moving H=0 contour.
-- This keeps startup and mobile memory tied to shoreline complexity, not patch area.
local edgeX, edgeZ, edgeDiag = {}, {}, {}
for i = 0, N - 2 do
	edgeX[i], edgeDiag[i] = {}, {}
	for j = 0, N - 1 do
		edgeX[i][j] = {} :: Edge
	end
	for j = 0, N - 2 do
		edgeDiag[i][j] = {} :: Edge
	end
end
for i = 0, N - 1 do
	edgeZ[i] = {}
	for j = 0, N - 2 do
		edgeZ[i][j] = {} :: Edge
	end
end

local function addFace(a: Vertex, b: Vertex, c: Vertex): number
	local face = em:AddTriangle(a.position, b.position, c.position)
	em:SetFaceNormals(face, { a.normal, b.normal, c.normal })
	em:SetFaceColors(face, { a.color, b.color, c.color })
	return face
end

local tri1, tri2 = {}, {}
for i = 0, N - 2 do
	tri1[i], tri2[i] = {}, {}
	for j = 0, N - 2 do
		tri1[i][j] = { first = {}, second = {} } :: TriangleState
		tri2[i][j] = { first = {}, second = {} } :: TriangleState
	end
end

-- CreateMeshPartAsync needs one initial face. All actual topology is installed on the
-- first render step and remains editable afterwards.
local placeholderFace = addFace(grid[0][0], grid[0][1], grid[1][0])
local surface = ((game:GetService("AssetService") :: any)):CreateMeshPartAsync(Content.fromObject(em))
em:RemoveFace(placeholderFace)
surface.Name = "Ocean"
surface.Anchored = true
surface.CanCollide = false
surface.CanQuery = false
surface.CastShadow = false
surface.Material = Enum.Material.SmoothPlastic
surface.Color = Color3.new(1, 1, 1)
surface.Transparency = 0
-- The material response exposes the normals already produced by the physical surface;
-- it is not an additional visual wave layer.
surface.Reflectance = 0.08
surface.Position = Vector3.new(cx, SEA, cz)
surface.Parent = Workspace

local surfaceY = table.create(N * N, 0)
local signedDepth = table.create(N * N, 0)
local colors = table.create(N * N)
local depthRefresh = 0

local function ensureEdge(edge: Edge): Vertex
	if edge.vertex == nil then
		edge.vertex = newVertex(Vector3.new(0, 0, 0))
	end
	return edge.vertex
end

local function removeSlot(slot: FaceSlot)
	if slot.face ~= nil then
		em:RemoveFace(slot.face)
		slot.face, slot.a, slot.b, slot.c = nil, nil, nil, nil
	end
end

local function setSlot(slot: FaceSlot, a: Vertex, b: Vertex, c: Vertex)
	if slot.face == nil then
		slot.face = addFace(a, b, c)
	elseif slot.a ~= a.position or slot.b ~= b.position or slot.c ~= c.position then
		em:SetFaceVertices(slot.face, { a.position, b.position, c.position })
		em:SetFaceNormals(slot.face, { a.normal, b.normal, c.normal })
		em:SetFaceColors(slot.face, { a.color, b.color, c.color })
	end
	slot.a, slot.b, slot.c = a.position, b.position, c.position
end

local function setIntersection(edge: Edge, a: number, b: number): Vertex
	local vertex = ensureEdge(edge)
	local pa, pb = signedDepth[a], signedDepth[b]
	local denom = pa - pb
	local t = if math.abs(denom) > 1e-12 then math.clamp(pa / denom, 0, 1) else 0.5
	local x = localX[a] + (localX[b] - localX[a]) * t
	local y = surfaceY[a] + (surfaceY[b] - surfaceY[a]) * t
	local z = localZ[a] + (localZ[b] - localZ[a]) * t
	em:SetPosition(vertex.position, Vector3.new(x, y, z))
	em:SetNormal(vertex.normal, Vector3.yAxis)
	em:SetColor(vertex.color, colors[a]:Lerp(colors[b], t))
	em:SetColorAlpha(vertex.color, 0)
	return vertex
end

-- Sutherland-Hodgman specialised to one triangle. The two possible output faces are
-- allocated only for the mixed case; no water triangle ever crosses a dry terrain vertex.
local function clipTriangle(
	state: TriangleState,
	a: number,
	b: number,
	c: number,
	edgeAB: Edge,
	edgeBC: Edge,
	edgeCA: Edge
)
	local inA, inB, inC = signedDepth[a] > 0, signedDepth[b] > 0, signedDepth[c] > 0
	local count = (if inA then 1 else 0) + (if inB then 1 else 0) + (if inC then 1 else 0)
	if count == 0 then
		removeSlot(state.first)
		removeSlot(state.second)
		return
	end

	local va, vb, vc = vertexAt[a], vertexAt[b], vertexAt[c]
	if count == 3 then
		setSlot(state.first, va, vb, vc)
		removeSlot(state.second)
		return
	end

	if count == 1 then
		removeSlot(state.second)
		if inA then
			setSlot(state.first, va, setIntersection(edgeAB, a, b), setIntersection(edgeCA, c, a))
		elseif inB then
			setSlot(state.first, setIntersection(edgeAB, a, b), vb, setIntersection(edgeBC, b, c))
		else
			setSlot(state.first, setIntersection(edgeBC, b, c), vc, setIntersection(edgeCA, c, a))
		end
		return
	end

	if not inA then
		local iab, ica = setIntersection(edgeAB, a, b), setIntersection(edgeCA, c, a)
		setSlot(state.first, iab, vb, vc)
		setSlot(state.second, iab, vc, ica)
	elseif not inB then
		local iab, ibc = setIntersection(edgeAB, a, b), setIntersection(edgeBC, b, c)
		setSlot(state.first, va, iab, ibc)
		setSlot(state.second, va, ibc, vc)
	else
		local ibc, ica = setIntersection(edgeBC, b, c), setIntersection(edgeCA, c, a)
		setSlot(state.first, va, vb, ibc)
		setSlot(state.second, va, ibc, ica)
	end
end

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
	local water, foam = ocean.water, ocean.foam
	local wetCount, dryCount, shoreCount = 0, 0, 0
	local runupCells, foamCells, forcingCells = 0, 0, 0
	local maxRunupGround, maxFoam, forcingSum = SEA, 0, 0
	local visiblePeak, visibleTrough = -math.huge, math.huge

	for i = 0, N - 1 do
		local rowBase = i * N
		local fadeI = fadeArr[i]
		for j = 0, N - 1 do
			local c = rowBase + j + 1
			local H = water[c]
			local isWet = wet[c]
			if isWet then
				wetCount += 1
				surfaceY[c] = h[c] * fadeI * fadeArr[j]
				signedDepth[c] = H
				visiblePeak = math.max(visiblePeak, surfaceY[c])
				visibleTrough = math.min(visibleTrough, surfaceY[c])
			else
				dryCount += 1
				surfaceY[c] = 0
				-- A dry exact-waterline sample must stay outside the visible polygon.
				signedDepth[c] = math.min(SEA - groundY[c], -CLIP_EPS)
			end

			if isWet and groundY[c] > SEA then
				runupCells += 1
				maxRunupGround = math.max(maxRunupGround, groundY[c])
			end
			local shore = not isWet and ((i > 0 and wet[c - N]) or (i < N - 1 and wet[c + N]) or (j > 0 and wet[c - 1]) or (j < N - 1 and wet[c + 1]))
			if shore then
				shoreCount += 1
			end

			local foamRead = if H > 0 then math.clamp(foam[c] / H, 0, 1) else 0
			if foamRead > 0.01 then
				foamCells += 1
				maxFoam = math.max(maxFoam, foamRead)
			end
			local depthTint = math.clamp(1 - H / 20, 0, 1)
			colors[c] = DEEP:Lerp(MID, depthTint):Lerp(FOAM, foamRead)

			local forcing = ocean.exposure[c] * ocean.forceWindow[c]
			forcingSum += forcing
			if forcing > 0 then
				forcingCells += 1
			end
		end
	end

	for i = 0, N - 1 do
		local rowBase = i * N
		for j = 0, N - 1 do
			local c = rowBase + j + 1
			local y = surfaceY[c]
			local ym = (i > 0 and wet[c - N]) and surfaceY[c - N] or y
			local yp = (i < N - 1 and wet[c + N]) and surfaceY[c + N] or y
			local zm = (j > 0 and wet[c - 1]) and surfaceY[c - 1] or y
			local zp = (j < N - 1 and wet[c + 1]) and surfaceY[c + 1] or y
			local dhx = (yp - ym) / (2 * SP)
			local dhz = (zp - zm) / (2 * SP)
			local vertex = vertexAt[c]
			em:SetPosition(vertex.position, Vector3.new(localX[c], y, localZ[c]))
			em:SetNormal(vertex.normal, Vector3.new(-dhx, 1, -dhz).Unit)
			em:SetColor(vertex.color, colors[c])
			em:SetColorAlpha(vertex.color, 0)
		end
	end

	for i = 0, N - 2 do
		local rowBase = i * N
		for j = 0, N - 2 do
			local c = rowBase + j + 1
			clipTriangle(tri1[i][j], c, c + 1, c + N, edgeZ[i][j], edgeDiag[i][j], edgeX[i][j])
			clipTriangle(tri2[i][j], c + 1, c + N + 1, c + N, edgeX[i][j + 1], edgeZ[i + 1][j], edgeDiag[i][j])
		end
	end

	surface:SetAttribute("oceanPeak", ocean:peak())
	surface:SetAttribute("wetCells", wetCount)
	surface:SetAttribute("dryCells", dryCount)
	surface:SetAttribute("shoreCells", shoreCount)
	surface:SetAttribute("runupCells", runupCells)
	surface:SetAttribute("maxRunupGround", maxRunupGround)
	surface:SetAttribute("foamCells", foamCells)
	surface:SetAttribute("maxFoam", maxFoam)
	surface:SetAttribute("forcingCells", forcingCells)
	surface:SetAttribute("meanForcing", forcingSum / (N * N))
	surface:SetAttribute("visiblePeak", visiblePeak == -math.huge and 0 or visiblePeak)
	surface:SetAttribute("visibleTrough", visibleTrough == math.huge and 0 or visibleTrough)
end)
