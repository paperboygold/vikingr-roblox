--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local Vikingr = ReplicatedStorage:WaitForChild("Vikingr")
local WorldSpec = require(Vikingr.WorldSpec)
local ChunkStore = require(Vikingr.ChunkStore)
local TerrainField = require(Vikingr.TerrainField)

local TerrainWriter = {}

local MARKERS_NAME = "Vikingr_Map_Markers"

local function clearPrevious()
	workspace.Terrain:Clear()

	local markers = workspace:FindFirstChild(MARKERS_NAME)
	if markers then
		markers:Destroy()
	end

	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate then
		baseplate:Destroy()
	end
end

local function makeLabel(parent: Instance, config: WorldSpec.Config, name: string, x: number, z: number)
	local anchor = Instance.new("Part")
	anchor.Name = name .. "_Label"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(2, 2, 2)
	anchor.Position = WorldSpec.worldPoint(config, x, z, 72)
	anchor.Parent = parent

	local gui = Instance.new("BillboardGui")
	gui.Name = "Billboard"
	gui.Size = UDim2.fromOffset(160, 38)
	gui.StudsOffset = Vector3.new(0, 6, 0)
	gui.AlwaysOnTop = true
	gui.Parent = anchor

	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 0.25
	text.BackgroundColor3 = Color3.fromRGB(13, 18, 20)
	text.BorderSizePixel = 0
	text.Text = name
	text.TextColor3 = Color3.fromRGB(235, 239, 226)
	text.TextScaled = true
	text.Font = Enum.Font.Garamond
	text.Size = UDim2.fromScale(1, 1)
	text.Parent = gui
end

local function makeRoute(parent: Instance, config: WorldSpec.Config, name: string, ax: number, az: number, bx: number, bz: number)
	local pa = WorldSpec.worldPoint(config, ax, az, config.seaLevel + 5)
	local pb = WorldSpec.worldPoint(config, bx, bz, config.seaLevel + 5)
	local mid = (pa + pb) / 2
	local length = (pb - pa).Magnitude

	local route = Instance.new("Part")
	route.Name = name
	route.Anchored = true
	route.CanCollide = false
	route.CanQuery = false
	route.CanTouch = false
	route.Material = Enum.Material.Neon
	route.Color = Color3.fromRGB(44, 145, 178)
	route.Transparency = 0.42
	route.Size = Vector3.new(4, 1, length)
	route.CFrame = CFrame.lookAt(mid, pb)
	route.Parent = parent
end

local function placeSpawn(config: WorldSpec.Config, state: ChunkStore.State, fieldState: TerrainField.State)
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if not spawn then
		spawn = Instance.new("SpawnLocation")
		spawn.Name = "SpawnLocation"
		spawn.Parent = workspace
	end

	-- spawn at the first emergent port (a sheltered coast); fall back to map centre
	local port = fieldState.sites.ports[1]
	local x, z = 0, 0
	if port ~= nil then
		x, z = port.x, port.z
	end
	local key = ChunkStore.cellKey(x, z)
	local height = TerrainField.sampleHeight(config, fieldState, x, z)
	if state.land[key] == nil then
		height = config.seaLevel + 12
	end
	spawn.Anchored = true
	spawn.Size = Vector3.new(14, 1, 14)
	spawn.Position = WorldSpec.worldPoint(config, x, z, height + 5)
	spawn.Material = Enum.Material.WoodPlanks
	spawn.Color = Color3.fromRGB(111, 80, 48)
end

local function alignedFloor(value: number, resolution: number): number
	return math.floor(value / resolution) * resolution
end

local function alignedCeil(value: number, resolution: number): number
	return math.ceil(value / resolution) * resolution
end


local function makeVoxelChunk(
	config: WorldSpec.Config,
	fieldState: TerrainField.State,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	minZ: number,
	maxZ: number
): ({ [number]: { [number]: { [number]: Enum.Material } } }, { [number]: { [number]: { [number]: number } } }, number)
	local resolution = config.voxelResolution
	local xCount = math.floor((maxX - minX) / resolution)
	local yCount = math.floor((maxY - minY) / resolution)
	local zCount = math.floor((maxZ - minZ) / resolution)
	local materials = {}
	local occupancies = {}
	local voxels = xCount * yCount * zCount

	for xi = 1, xCount do
		local materialX = {}
		local occupancyX = {}
		local worldX = minX + (xi - 0.5) * resolution
		local cellX = worldX / config.cellSize - 0.5

		for yi = 1, yCount do
			local materialY = {}
			local occupancyY = {}
			local worldY = minY + (yi - 0.5) * resolution

			for zi = 1, zCount do
				local worldZ = minZ + (zi - 0.5) * resolution
				local cellZ = worldZ / config.cellSize - 0.5
				local region, height, waterKind, waterHeight, sampleMaterial = TerrainField.sampleVoxel(config, fieldState, cellX, cellZ)
				local material = Enum.Material.Air
				local occupancy = 0

				if region ~= nil then
					local surface = (height - worldY) / resolution + 0.5
					occupancy = math.clamp(surface, 0, 1)
					if occupancy > 0 then
						material = sampleMaterial
					end
				end

				-- Native Terrain owns the whole visible body: sea, rivers, and lakes. The
				-- custom branch writes no Terrain water, avoiding two overlapping surfaces.
				if waterKind ~= nil and config.waterRenderer == "terrain" then
					if worldY <= waterHeight and occupancy < 0.95 then
						material = Enum.Material.Water
						occupancy = math.max(occupancy, math.clamp((waterHeight - worldY) / resolution + 0.5, 0, 1))
					end
				end

				materialY[zi] = material
				occupancyY[zi] = occupancy
			end

			materialX[yi] = materialY
			occupancyX[yi] = occupancyY
		end

		materials[xi] = materialX
		occupancies[xi] = occupancyX
	end

	return materials, occupancies, voxels
end

local function chunkMaxY(
	config: WorldSpec.Config,
	fieldState: TerrainField.State,
	startX: number,
	endX: number,
	startZ: number,
	endZ: number,
	minimum: number
): number
	local maxHeight = minimum
	for x = startX, endX do
		for z = startZ, endZ do
			if TerrainField.sampleRegion(config, fieldState, x, z) ~= nil then
				maxHeight = math.max(maxHeight, TerrainField.sampleHeight(config, fieldState, x, z))
			end
		end
	end
	return alignedCeil(math.min(config.maxHeight, maxHeight + config.voxelResolution * 3), config.voxelResolution)
end

-- Mirrors chunkMaxY for the FLOOR of the region. Previously the writer used a single
-- GLOBAL minY = seaLevel - 8 studs for the whole map, so nothing deeper than 8 studs below
-- sea level could ever be voxelized regardless of what the field reported — the real cause
-- of the "ocean floor is a single 4x4x4 block" bug. Now every chunk's Y-range genuinely
-- reaches down to its own seabed.
local function chunkMinY(
	config: WorldSpec.Config,
	fieldState: TerrainField.State,
	startX: number,
	endX: number,
	startZ: number,
	endZ: number,
	maximum: number
): number
	local minHeight = maximum
	for x = startX, endX do
		for z = startZ, endZ do
			if TerrainField.sampleRegion(config, fieldState, x, z) ~= nil then
				minHeight = math.min(minHeight, TerrainField.sampleHeight(config, fieldState, x, z))
			end
		end
	end
	return alignedFloor(math.max(config.seaLevel - config.waterDepth - 32, minHeight - config.voxelResolution), config.voxelResolution)
end

function TerrainWriter.write(config: WorldSpec.Config, state: ChunkStore.State, providedFieldState: TerrainField.State?): { [string]: number }
	debug.profilebegin("Vikingr.TerrainWriter.clear")
	clearPrevious()
	debug.profileend()

	Lighting.ClockTime = 12
	Lighting.Brightness = 2
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.4
	local terrainWater = WorldSpec.Tuning.terrainWater
	workspace.Terrain.WaterColor = terrainWater.color
	workspace.Terrain.WaterTransparency = terrainWater.transparency
	workspace.Terrain.WaterReflectance = terrainWater.reflectance
	workspace.Terrain.WaterWaveSize = terrainWater.waveSize
	workspace.Terrain.WaterWaveSpeed = terrainWater.waveSpeed
	pcall(function()
		workspace.StreamingEnabled = true
	end)

	local stats = {
		chunks = 0,
		cells = 0,
		terrainWrites = 0,
		voxelWrites = 0,
		voxelsWritten = 0,
		peakChunkVoxels = 0,
		markers = 0,
	}

	local fieldState = providedFieldState or TerrainField.build(config, state)
	local resolution = config.voxelResolution
	local halfW = math.floor(config.width / 2)
	local halfD = math.floor(config.depth / 2)
	local chunkCells = config.voxelChunkCells
	local chunkCountX = math.ceil(config.width / chunkCells)
	local chunkCountZ = math.ceil(config.depth / chunkCells)

	-- Every chunk is voxelized: land and seabed remain real Terrain. In the native render
	-- plan, the same chunk write fills ocean, river, and lake columns to their field surface.
	for chunkX = 0, chunkCountX - 1 do
		for chunkZ = 0, chunkCountZ - 1 do
			local startX = -halfW + chunkX * chunkCells
			local startZ = -halfD + chunkZ * chunkCells
			local endX = math.min(startX + chunkCells - 1, halfW - 1)
			local endZ = math.min(startZ + chunkCells - 1, halfD - 1)

			local minY = chunkMinY(config, fieldState, startX, endX, startZ, endZ, config.seaLevel)
			local maxY = chunkMaxY(config, fieldState, startX, endX, startZ, endZ, config.seaLevel + resolution)
			local minX = alignedFloor(startX * config.cellSize, resolution)
			local maxX = alignedCeil((endX + 1) * config.cellSize, resolution)
			local minZ = alignedFloor(startZ * config.cellSize, resolution)
			local maxZ = alignedCeil((endZ + 1) * config.cellSize, resolution)
			local region = Region3.new(
				Vector3.new(minX, minY, minZ),
				Vector3.new(maxX, maxY, maxZ)
			):ExpandToGrid(resolution)
			local materials, occupancies, voxels = makeVoxelChunk(
				config,
				fieldState,
				minX,
				maxX,
				minY,
				maxY,
				minZ,
				maxZ
			)

			workspace.Terrain:WriteVoxels(region, resolution, materials, occupancies)
			stats.chunks += 1
			stats.terrainWrites += 1
			stats.voxelWrites += 1
			stats.voxelsWritten += voxels
			stats.peakChunkVoxels = math.max(stats.peakChunkVoxels, voxels)
			if stats.voxelWrites % config.voxelChunksPerYield == 0 then
				task.wait()
			end
		end
	end
	stats.cells = stats.chunks * chunkCells * chunkCells

	placeSpawn(config, state, fieldState)

	local markers = Instance.new("Folder")
	markers.Name = MARKERS_NAME
	markers.Parent = workspace

	for i, port in ipairs(fieldState.sites.ports) do
		makeLabel(markers, config, "Port " .. i, port.x, port.z)
		stats.markers += 1
	end

	for _, route in ipairs(fieldState.sites.routes) do
		makeRoute(markers, config, "SeaLane", route.a.x, route.a.z, route.b.x, route.b.z)
		stats.markers += 1
	end

	return stats
end

function TerrainWriter.writeColumns(config: WorldSpec.Config, state: ChunkStore.State): { [string]: number }
	local stats = {
		chunks = 0,
		cells = 0,
		terrainWrites = 0,
		markers = 0,
	}

	local worldSize = Vector3.new(config.width * config.cellSize, config.waterDepth, config.depth * config.cellSize)
	if config.waterRenderer == "terrain" then
		workspace.Terrain:FillBlock(
			CFrame.new(0, config.seaLevel - config.waterDepth / 2, 0),
			worldSize,
			Enum.Material.Water
		)
		stats.terrainWrites += 1
	end

	Hash.iterDict(state.chunks, nil, function(_, _chunkKey, cells)
		stats.chunks += 1
		for _, cellKey in ipairs(cells) do
			local x, z = ChunkStore.parseCellKey(cellKey)
			local height = state.height[cellKey]
			local material = state.material[cellKey]
			local columnHeight = math.max(4, height)
			workspace.Terrain:FillBlock(
				CFrame.new((x + 0.5) * config.cellSize, columnHeight / 2, (z + 0.5) * config.cellSize),
				Vector3.new(config.cellSize, columnHeight, config.cellSize),
				material
			)
			stats.cells += 1
			stats.terrainWrites += 1
		end
		return nil
	end)

	return stats
end

return TerrainWriter
