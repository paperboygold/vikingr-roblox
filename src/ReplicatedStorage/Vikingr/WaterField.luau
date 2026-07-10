--!strict
--!native

-- WaterField is the sparse geometry descent from WaterSim's conservative coarse state.
-- Rivers are reconstructed edge-by-edge as connected D8 capsules. Lake footprints are the
-- positive part of their original signed basin head, with the neighbouring dry samples kept
-- as the negative side of the zero contour. The map is keyed at Terrain-column resolution;
-- no second visible surface is created.

local WorldSpec = require(script.Parent.WorldSpec)
local Hash = require(script.Parent.Hash)
local FieldMap = require(script.Parent.FieldMap)

local WaterField = {}

export type WaterKind = "river" | "lake"
export type Sample = {
	surface: number,
	depth: number,
	velX: number,
	velZ: number,
	kind: WaterKind,
	owner: number,
}
export type State = {
	resolution: number,
	cellSize: number,
	samples: Hash.AddressTable,
	stats: { [string]: number },
}

local function riverWidth(Q: number): number
	local T = WorldSpec.Tuning.water
	return math.clamp(T.widthCoeff * math.sqrt(math.max(0, Q)), T.minWidth, T.maxWidth)
end

local function riverDepth(Q: number): number
	local T = WorldSpec.Tuning.water
	return math.clamp(T.depthCoeff * math.max(0, Q) ^ T.depthExp, T.minDepth, T.maxDepth)
end

-- Total ordering makes insertWith independent of traversal order. The deeper reconstruction
-- wins together with its own potential and velocity state.
local function mergeDeeper(newValue: Sample, oldValue: Sample): Sample
	if newValue.depth ~= oldValue.depth then
		return if newValue.depth > oldValue.depth then newValue else oldValue
	end
	if newValue.surface ~= oldValue.surface then
		return if newValue.surface < oldValue.surface then newValue else oldValue
	end
	if newValue.kind ~= oldValue.kind then
		return if newValue.kind == "river" then newValue else oldValue
	end
	return if newValue.owner < oldValue.owner then newValue else oldValue
end

local function insertSample(samples: Hash.AddressTable, ix: number, iz: number, sample: Sample)
	samples:insertWith(Hash.cellCoord(ix, iz), sample, mergeDeeper)
end

local function percentile(sorted: { number }, fraction: number): number
	if #sorted == 0 then
		return 0
	end
	return sorted[math.clamp(math.ceil(#sorted * fraction), 1, #sorted)]
end

local function connected(cells: { [number]: boolean }, count: number): boolean
	if count <= 1 then
		return true
	end
	local first = next(cells)
	if first == nil then
		return false
	end
	local seen: { [number]: boolean } = { [first] = true }
	local stack: { number } = { first }
	local visited = 0
	while #stack > 0 do
		local coord = stack[#stack]
		stack[#stack] = nil
		visited += 1
		local x, z = Hash.splitCellCoord(coord)
		for dx = -1, 1 do
			for dz = -1, 1 do
				if dx ~= 0 or dz ~= 0 then
					local nk = Hash.cellCoord(x + dx, z + dz)
					if cells[nk] and not seen[nk] then
						seen[nk] = true
						stack[#stack + 1] = nk
					end
				end
			end
		end
	end
	return visited == count
end

local function bilerp(a00: number, a10: number, a01: number, a11: number, fx: number, fz: number): number
	local top = WorldSpec.lerp(a00, a10, fx)
	local bottom = WorldSpec.lerp(a01, a11, fx)
	return WorldSpec.lerp(top, bottom, fz)
end

local function rasterizeRivers(config: WorldSpec.Config, fm: FieldMap.FieldMap, samples: Hash.AddressTable)
	local resolution = config.voxelResolution
	local cellSize = config.cellSize
	local receiver = fm.graph["receiver"] or {}
	local land = fm.mask["land"] or {}
	local reservoir = fm.mask["reservoirBoundary"] or {}
	local surfaces = fm.scalar["waterSurface"] or {}
	local velocitiesX = fm.scalar["flowVelX"] or {}
	local velocitiesZ = fm.scalar["flowVelZ"] or {}
	local widths: { number } = {}
	local capsuleCount = 0
	local mouthCount = 0
	local mouthSurfaceError = 0

	local function surfaceAt(key: FieldMap.CellKey): number
		return surfaces[key] or (fm.scalar["waterLevel"] or {})[key] or config.seaLevel
	end

	local rivers = FieldMap.sortedMask(fm, "river", nil)
	for _, key in ipairs(rivers) do
		local axCell, azCell = FieldMap.parseKey(key)
		local rec = receiver[key]
		local recKey = if rec ~= nil then rec[1] else nil
		local bxCell, bzCell = axCell, azCell
		if recKey ~= nil then
			bxCell, bzCell = FieldMap.parseKey(recKey)
		end

		local Q0 = FieldMap.getCount(fm, "flowAcc", key)
		local Q1 = if recKey ~= nil and land[recKey]
			then math.max(Q0, FieldMap.getCount(fm, "flowAcc", recKey)) else Q0
		local W0, W1 = riverWidth(Q0), riverWidth(Q1)
		local D0, D1 = riverDepth(Q0), riverDepth(Q1)
		widths[#widths + 1] = W0
		capsuleCount += 1

		local ax, az = (axCell + 0.5) * cellSize, (azCell + 0.5) * cellSize
		local bx, bz = (bxCell + 0.5) * cellSize, (bzCell + 0.5) * cellSize
		local vx, vz = bx - ax, bz - az
		local length2 = vx * vx + vz * vz
		local length = math.sqrt(length2)
		local dirX, dirZ = 0, 0
		if length > 0 then
			dirX, dirZ = vx / length, vz / length
		end

		local surface0 = surfaceAt(key)
		local surface1 = if reservoir[key] then config.seaLevel
			elseif recKey ~= nil then surfaceAt(recKey) else surface0
		if reservoir[key] then
			-- The coarse reservoir cell and its exterior endpoint share one exact potential.
			mouthSurfaceError = math.max(mouthSurfaceError, math.abs(surface0 - config.seaLevel))
			surface0 = config.seaLevel
			surface1 = config.seaLevel
			mouthCount += 1
		end

		local maxRadius = math.max(W0, W1) * 0.5
		local minIX = math.floor((math.min(ax, bx) - maxRadius) / resolution)
		local maxIX = math.floor((math.max(ax, bx) + maxRadius) / resolution)
		local minIZ = math.floor((math.min(az, bz) - maxRadius) / resolution)
		local maxIZ = math.floor((math.max(az, bz) + maxRadius) / resolution)
		for ix = minIX, maxIX do
			local px = (ix + 0.5) * resolution
			for iz = minIZ, maxIZ do
				local pz = (iz + 0.5) * resolution
				local t = 0
				if length2 > 0 then
					t = math.clamp(((px - ax) * vx + (pz - az) * vz) / length2, 0, 1)
				end
				local dx, dz = px - (ax + vx * t), pz - (az + vz * t)
				local distance = math.sqrt(dx * dx + dz * dz)
				local width = WorldSpec.lerp(W0, W1, t)
				local radius = width * 0.5
				if distance < radius then
					local fullDepth = WorldSpec.lerp(D0, D1, t)
					local depth = fullDepth * (1 - (distance / radius) ^ 2)
					if depth > 0 then
						insertSample(samples, ix, iz, {
							surface = WorldSpec.lerp(surface0, surface1, t),
							depth = depth,
							velX = WorldSpec.lerp(velocitiesX[key] or dirX,
								if recKey ~= nil then velocitiesX[recKey] or dirX else dirX, t),
							velZ = WorldSpec.lerp(velocitiesZ[key] or dirZ,
								if recKey ~= nil then velocitiesZ[recKey] or dirZ else dirZ, t),
							kind = "river",
							owner = key,
						})
					end
				end
			end
		end
	end

	table.sort(widths)
	return {
		capsuleCount = capsuleCount,
		mouthCount = mouthCount,
		mouthSurfaceError = mouthSurfaceError,
		riverMedianWidth = percentile(widths, 0.5),
		riverP95Width = percentile(widths, 0.95),
		riverMaxWidth = percentile(widths, 1),
	}
end

local function rasterizeLakes(config: WorldSpec.Config, fm: FieldMap.FieldMap, samples: Hash.AddressTable)
	local resolution = config.voxelResolution
	local cellSize = config.cellSize
	local basinField = fm.scalar["basin"] or {}
	local levels = fm.scalar["waterLevel"] or {}
	local originalBeds = fm.scalar["elevBeforeWater"] or fm.scalar["elevHydro"] or {}
	local originalHeads = fm.scalar["lakeHeadOriginal"] or {}
	local lakeTolerance = WorldSpec.Tuning.hydrology.lakeTolerance
	local velX = fm.scalar["flowVelX"] or {}
	local velZ = fm.scalar["flowVelZ"] or {}
	local basins: { [number]: any } = {}

	for _, key in ipairs(FieldMap.sortedMask(fm, "lake", nil)) do
		local id = basinField[key]
		if id ~= nil then
			local x, z = FieldMap.parseKey(key)
			local basin = basins[id]
			if basin == nil then
				basin = {
					id = id,
					surface = levels[key] or config.seaLevel,
					count = 0,
					maxHead = 0,
					minX = x,
					maxX = x,
					minZ = z,
					maxZ = z,
					wet = {},
					heads = {},
				}
				basins[id] = basin
			end
			-- Hydrology's basin predicate is head > lakeTolerance. Preserve that signed
			-- predicate as the implicit field, so the zero contour lies between wet and dry
			-- samples instead of expanding to the next dry centre.
			local head = (originalHeads[key]
				or ((basin.surface :: number) - (originalBeds[key] or config.seaLevel))) - lakeTolerance
			basin.count += 1
			basin.maxHead = math.max(basin.maxHead, head)
			basin.minX, basin.maxX = math.min(basin.minX, x), math.max(basin.maxX, x)
			basin.minZ, basin.maxZ = math.min(basin.minZ, z), math.max(basin.maxZ, z)
			basin.wet[key] = true
			basin.heads[key] = head
		end
	end

	local basinCount = 0
	local contiguousBasins = 0
	local lakeColumns = 0
	local minMaxDepth, maxMaxDepth = math.huge, 0
	local basinIds: { number } = {}
	for id in pairs(basins) do basinIds[#basinIds + 1] = id end
	table.sort(basinIds)
	local function coarseValue(field: { [number]: number }, x: number, z: number): number?
		if not FieldMap.inBounds(fm, x, z) then
			return nil
		end
		return field[FieldMap.cellKey(x, z)]
	end
	for _, id in ipairs(basinIds) do
		local basin = basins[id]
		basinCount += 1
		-- One dry-cell halo supplies the signed side of every bilinear face touching the
		-- original basin; no positive value is stamped beyond that implicit contour.
		for key in pairs(basin.wet) do
			local x, z = FieldMap.parseKey(key)
			for dx = -1, 1 do
				for dz = -1, 1 do
					local nx, nz = x + dx, z + dz
					if FieldMap.inBounds(fm, nx, nz) then
						local nk = FieldMap.cellKey(nx, nz)
						if basin.heads[nk] == nil then
							basin.heads[nk] = basin.surface - (originalBeds[nk] or config.seaLevel) - lakeTolerance
						end
					end
				end
			end
		end

		local area = basin.count * cellSize * cellSize
		local maximumDepth = WorldSpec.Tuning.water.lakeDepthCoeff * math.sqrt(area / math.pi)
		minMaxDepth = math.min(minMaxDepth, maximumDepth)
		maxMaxDepth = math.max(maxMaxDepth, maximumDepth)
		local minWorldX = (basin.minX - 0.5) * cellSize
		local maxWorldX = (basin.maxX + 1.5) * cellSize
		local minWorldZ = (basin.minZ - 0.5) * cellSize
		local maxWorldZ = (basin.maxZ + 1.5) * cellSize
		local basinCells: { [number]: boolean } = {}
		local basinColumns = 0
		for ix = math.floor(minWorldX / resolution), math.floor(maxWorldX / resolution) do
			local worldX = (ix + 0.5) * resolution
			local x = worldX / cellSize - 0.5
			local x0, fx = math.floor(x), x - math.floor(x)
			for iz = math.floor(minWorldZ / resolution), math.floor(maxWorldZ / resolution) do
				local worldZ = (iz + 0.5) * resolution
				local z = worldZ / cellSize - 0.5
				local z0, fz = math.floor(z), z - math.floor(z)
				local h00 = coarseValue(basin.heads, x0, z0)
				local h10 = coarseValue(basin.heads, x0 + 1, z0)
				local h01 = coarseValue(basin.heads, x0, z0 + 1)
				local h11 = coarseValue(basin.heads, x0 + 1, z0 + 1)
				if h00 ~= nil and h10 ~= nil and h01 ~= nil and h11 ~= nil and basin.maxHead > 0 then
					local head = bilerp(h00, h10, h01, h11, fx, fz)
					if head > 0 then
						local depth = maximumDepth * math.clamp(head / basin.maxHead, 0, 1)
						if depth > 0 then
							local coord = Hash.cellCoord(ix, iz)
							if not basinCells[coord] then
								basinCells[coord] = true
								basinColumns += 1
							end
							insertSample(samples, ix, iz, {
								surface = basin.surface,
								depth = depth,
								velX = bilerp(coarseValue(velX, x0, z0) or 0,
									coarseValue(velX, x0 + 1, z0) or 0,
									coarseValue(velX, x0, z0 + 1) or 0,
									coarseValue(velX, x0 + 1, z0 + 1) or 0, fx, fz),
								velZ = bilerp(coarseValue(velZ, x0, z0) or 0,
									coarseValue(velZ, x0 + 1, z0) or 0,
									coarseValue(velZ, x0, z0 + 1) or 0,
									coarseValue(velZ, x0 + 1, z0 + 1) or 0, fx, fz),
								kind = "lake",
								owner = id,
							})
						end
					end
				end
			end
		end
		lakeColumns += basinColumns
		if basinColumns > 0 and connected(basinCells, basinColumns) then
			contiguousBasins += 1
		end
	end

	return {
		lakeBasins = basinCount,
		contiguousLakeBasins = contiguousBasins,
		lakeColumnsBeforeMerge = lakeColumns,
		lakeAreaBeforeMerge = lakeColumns * resolution * resolution,
		lakeMinMaximumDepth = if minMaxDepth == math.huge then 0 else minMaxDepth,
		lakeMaxMaximumDepth = maxMaxDepth,
	}
end

-- Validation-only replay of the capsule footprint. It is intentionally outside build() so
-- geometry construction is not charged for a second per-edge connectivity traversal.
function WaterField.disconnectedCapsules(config: WorldSpec.Config, fm: FieldMap.FieldMap): number
	local resolution = config.voxelResolution
	local cellSize = config.cellSize
	local receiver = fm.graph["receiver"] or {}
	local disconnected = 0
	for _, key in ipairs(FieldMap.sortedMask(fm, "river", nil)) do
		local axCell, azCell = FieldMap.parseKey(key)
		local rec = receiver[key]
		local recKey = if rec ~= nil then rec[1] else nil
		local bxCell, bzCell = axCell, azCell
		if recKey ~= nil then bxCell, bzCell = FieldMap.parseKey(recKey) end
		local Q0 = FieldMap.getCount(fm, "flowAcc", key)
		local Q1 = if recKey ~= nil then math.max(Q0, FieldMap.getCount(fm, "flowAcc", recKey)) else Q0
		local W0, W1 = riverWidth(Q0), riverWidth(Q1)
		local ax, az = (axCell + 0.5) * cellSize, (azCell + 0.5) * cellSize
		local bx, bz = (bxCell + 0.5) * cellSize, (bzCell + 0.5) * cellSize
		local vx, vz = bx - ax, bz - az
		local length2 = vx * vx + vz * vz
		local maxRadius = math.max(W0, W1) * 0.5
		local cells: { [number]: boolean } = {}
		local count = 0
		for ix = math.floor((math.min(ax, bx) - maxRadius) / resolution),
				math.floor((math.max(ax, bx) + maxRadius) / resolution) do
			local px = (ix + 0.5) * resolution
			for iz = math.floor((math.min(az, bz) - maxRadius) / resolution),
					math.floor((math.max(az, bz) + maxRadius) / resolution) do
				local pz = (iz + 0.5) * resolution
				local t = if length2 > 0
					then math.clamp(((px - ax) * vx + (pz - az) * vz) / length2, 0, 1) else 0
				local dx, dz = px - (ax + vx * t), pz - (az + vz * t)
				if math.sqrt(dx * dx + dz * dz) < WorldSpec.lerp(W0, W1, t) * 0.5 then
					local coord = Hash.cellCoord(ix, iz)
					if not cells[coord] then
						cells[coord] = true
						count += 1
					end
				end
			end
		end
		if not connected(cells, count) then disconnected += 1 end
	end
	return disconnected
end

function WaterField.build(config: WorldSpec.Config, fm: FieldMap.FieldMap): State
	-- The production map occupies about twice the coarse cell count at 4-stud resolution.
	-- Supplying that sparse capacity once avoids resize-and-reinsert work during rasterization.
	local samples = Hash.CoordMap(4096)
	local riverStats = rasterizeRivers(config, fm, samples)
	local lakeStats = rasterizeLakes(config, fm, samples)
	local stats: { [string]: number } = {}
	for name, value in pairs(riverStats) do stats[name] = value end
	for name, value in pairs(lakeStats) do stats[name] = value end

	local riverColumns, lakeColumns = 0, 0
	local renderedBasins: { [number]: boolean } = {}
	samples:iter(function(_coord: number, sample: Sample)
		if sample.kind == "river" then
			riverColumns += 1
		else
			lakeColumns += 1
			renderedBasins[sample.owner] = true
		end
	end)
	local renderedBasinCount = 0
	for _ in pairs(renderedBasins) do renderedBasinCount += 1 end
	stats.sampleCount = samples:len()
	stats.riverColumns = riverColumns
	stats.lakeColumns = lakeColumns
	stats.renderedLakeArea = lakeColumns * config.voxelResolution * config.voxelResolution
	stats.renderedLakeBasins = renderedBasinCount
	-- Project the resolved mouth footprint back onto its prescribed reservoir potential.
	-- Depth and velocity remain those selected by the deeper-overlap merge.
	for _, key in ipairs(FieldMap.sortedMask(fm, "reservoirBoundary", nil)) do
		local x, z = FieldMap.parseKey(key)
		local centerX, centerZ = (x + 0.5) * config.cellSize, (z + 0.5) * config.cellSize
		local radius = riverWidth(FieldMap.getCount(fm, "flowAcc", key)) * 0.5
		for ix = math.floor((centerX - radius) / config.voxelResolution),
				math.floor((centerX + radius) / config.voxelResolution) do
			local worldX = (ix + 0.5) * config.voxelResolution
			for iz = math.floor((centerZ - radius) / config.voxelResolution),
					math.floor((centerZ + radius) / config.voxelResolution) do
				local worldZ = (iz + 0.5) * config.voxelResolution
				if (worldX - centerX) ^ 2 + (worldZ - centerZ) ^ 2 < radius ^ 2 then
					local coord = Hash.cellCoord(ix, iz)
					local sample = samples:get(coord, nil) :: Sample?
					if sample ~= nil and sample.kind == "river" then
						samples:insertWith(coord, {
							surface = config.seaLevel,
							depth = sample.depth,
							velX = sample.velX,
							velZ = sample.velZ,
							kind = sample.kind,
							owner = sample.owner,
						}, function(newValue: Sample, _oldValue: Sample): Sample
							return newValue
						end)
					end
				end
			end
		end
	end
	-- Recheck the merged high-resolution state at the four columns surrounding every
	-- coarse reservoir centre. An overlapping insert must not displace the exact potential.
	local mouthError = stats.mouthSurfaceError or 0
	for _, key in ipairs(FieldMap.sortedMask(fm, "reservoirBoundary", nil)) do
		local x, z = FieldMap.parseKey(key)
		local centerX, centerZ = (x + 0.5) * config.cellSize, (z + 0.5) * config.cellSize
		local ix, iz = math.floor(centerX / config.voxelResolution), math.floor(centerZ / config.voxelResolution)
		for dx = -1, 0 do
			for dz = -1, 0 do
				local sample = samples:get(Hash.cellCoord(ix + dx, iz + dz), nil) :: Sample?
				if sample ~= nil and sample.kind == "river" then
					mouthError = math.max(mouthError, math.abs(sample.surface - config.seaLevel))
				end
			end
		end
	end
	stats.mouthSurfaceError = mouthError

	return {
		resolution = config.voxelResolution,
		cellSize = config.cellSize,
		samples = samples,
		stats = stats,
	}
end

function WaterField.sample(state: State, x: number, z: number): Sample?
	local worldX = (x + 0.5) * state.cellSize
	local worldZ = (z + 0.5) * state.cellSize
	local ix = math.floor(worldX / state.resolution)
	local iz = math.floor(worldZ / state.resolution)
	return state.samples:get(Hash.cellCoord(ix, iz), nil) :: Sample?
end

return WaterField
