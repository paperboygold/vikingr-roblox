--!strict
--!native

-- WaterSim — real shallow-water on the drainage network, in two moves:
--
--   carve()  — incise the channels into the terrain (elevHydro): a monotone-descending
--              centerline that reaches BELOW sea level at every river mouth (so rivers
--              open to the ocean), widened by discharge with a parabolic cross-section
--              over a >= 1-cell radius (so diagonal steps leave no bar). This is what
--              fixes the "sand dam at the mouth", the "mud bar down the middle", and the
--              grass poking above the water — the water now has a real channel to sit in.
--
--   solve()  — the pipe model (Mei et al. 2007): water depth d and inter-cell flux f
--              evolved by the schedule-free sweep (erosion's sibling, a B/U flux
--              accumulator). River/lake cells are pinned sources, the sea is a sink at
--              sea level. Relaxes to a steady surface: flat lakes with organic (bilerp)
--              shorelines, connected rivers, and a velocity field for animated current.
--
-- Baked once; sampled O(1). waterDepth / waterSurface / flowVelX / flowVelZ are stored
-- in the FieldMap and read via bilerp at voxel time.

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)

local WaterSim = {}

local function channelDepth(config: WorldSpec.Config, Q: number): number
	local T = WorldSpec.Tuning.watersim
	return math.clamp(T.carveDepthCoeff * Q ^ T.carveDepthExp, T.carveMinDepth, T.carveMaxDepth)
end

-- ── incise channels into elevHydro ───────────────────────────────────────────
function WaterSim.carve(config: WorldSpec.Config, fm: FieldMap.FieldMap)
	local T = WorldSpec.Tuning.watersim
	local seaLevel = config.seaLevel
	local cellSize = config.cellSize
	local b = FieldMap.scalarField(fm, "elevHydro")
	local filled = fm.scalar["elevFilled"] or {}
	local receiver = fm.graph["receiver"] or {}
	local land = fm.mask["land"] or {}

	-- downstream order (highest filled first)
	local rivers = FieldMap.maskKeys(fm, "river")
	table.sort(rivers, function(a, c) return (filled[a] or 0) > (filled[c] or 0) end)

	-- pass 1: monotone descending centerline, reaching below sea at the mouth
	local maxAllowed: { [FieldMap.CellKey]: number } = {}
	local centerBed: { [FieldMap.CellKey]: number } = {}
	for _, key in ipairs(rivers) do
		local cur = math.min(b[key] or seaLevel, maxAllowed[key] or math.huge)
		local rec = receiver[key]
		local recKey = rec ~= nil and rec[1] or nil
		local toSea = recKey == nil or not land[recKey]
		if toSea then
			cur = math.min(cur, seaLevel - T.mouthDrop) -- open the mouth to the ocean
		end
		centerBed[key] = cur
		b[key] = cur
		if recKey ~= nil and land[recKey] then
			maxAllowed[recKey] = math.min(maxAllowed[recKey] or math.huge, cur - T.carveDrop)
		end
	end

	-- pass 2: widen to a parabolic cross-section (deepest at the centerline)
	for _, key in ipairs(rivers) do
		local cx, cz = FieldMap.parseKey(key)
		local Q = FieldMap.getCount(fm, "flowAcc", key)
		local W = math.clamp(WorldSpec.Tuning.water.widthCoeff * Q ^ WorldSpec.Tuning.water.widthExp,
			WorldSpec.Tuning.water.minWidth, WorldSpec.Tuning.water.maxWidth)
		local depth = channelDepth(config, Q)
		local bed = centerBed[key]
		local R = math.max(W * 0.5, T.carveMinRadius)
		local rc = math.ceil(R / cellSize)
		for dx = -rc, rc do
			for dz = -rc, rc do
				local nx, nz = cx + dx, cz + dz
				if FieldMap.inBounds(fm, nx, nz) then
					local d = math.sqrt((dx * cellSize) ^ 2 + (dz * cellSize) ^ 2)
					if d <= R then
						local nk = FieldMap.cellKey(nx, nz)
						if land[nk] then
							-- parabola: bed at centre → bed+depth at the bank
							local target = bed + depth * (d / R) ^ 2
							if target < (b[nk] or math.huge) then
								b[nk] = target
							end
						end
					end
				end
			end
		end
	end
end

-- ── shallow-water flux relaxation (pipe model) ───────────────────────────────
function WaterSim.solve(config: WorldSpec.Config, fm: FieldMap.FieldMap)
	local T = WorldSpec.Tuning.watersim
	local seaLevel = config.seaLevel
	local l = config.cellSize
	local area = l * l
	local A, g, dt, damp = T.pipeArea, T.gravity, T.dt, T.fluxDamp
	local b = FieldMap.scalarField(fm, "elevHydro")

	-- pinned sources: rivers (hydraulic depth) and lakes (spill − bed)
	local seed: { [FieldMap.CellKey]: number } = {}
	for _, key in ipairs(FieldMap.maskKeys(fm, "lake")) do
		seed[key] = math.max(seed[key] or 0, (fm.scalar["waterLevel"][key] or seaLevel) - (b[key] or seaLevel))
	end
	for _, key in ipairs(FieldMap.maskKeys(fm, "river")) do
		seed[key] = math.max(seed[key] or 0, channelDepth(config, FieldMap.getCount(fm, "flowAcc", key)))
	end

	-- The relaxation is many sweeps over the same topology. Collapse coordinates to
	-- a basis once; off-map neighbors are the explicit sea sink key 0.
	local landList = FieldMap.maskKeys(fm, "land")
	local cellCount = #landList
	local indexByKey: { [FieldMap.CellKey]: number } = {}
	local xByIndex: { number } = table.create(cellCount)
	local zByIndex: { number } = table.create(cellCount)
	local bed: { number } = table.create(cellCount)
	local depth: { number } = table.create(cellCount)
	local sourceFloor: { number? } = table.create(cellCount)
	for i, key in ipairs(landList) do
		indexByKey[key] = i
		local cx, cz = FieldMap.parseKey(key)
		xByIndex[i] = cx
		zByIndex[i] = cz
		bed[i] = b[key] or seaLevel
		local source = seed[key]
		sourceFloor[i] = source
		depth[i] = source or 0
	end

	local east: { number } = table.create(cellCount)
	local west: { number } = table.create(cellCount)
	local north: { number } = table.create(cellCount)
	local south: { number } = table.create(cellCount)
	local function neighborIndex(x: number, z: number): number
		if FieldMap.inBounds(fm, x, z) then
			return indexByKey[FieldMap.cellKey(x, z)] or 0
		end
		return 0
	end
	for i = 1, cellCount do
		local cx, cz = xByIndex[i], zByIndex[i]
		east[i] = neighborIndex(cx + 1, cz)
		west[i] = neighborIndex(cx - 1, cz)
		north[i] = neighborIndex(cx, cz + 1)
		south[i] = neighborIndex(cx, cz - 1)
	end

	local fluxE: { number } = table.create(cellCount, 0)
	local fluxW: { number } = table.create(cellCount, 0)
	local fluxN: { number } = table.create(cellCount, 0)
	local fluxS: { number } = table.create(cellCount, 0)
	local accel = dt * A * g / l

	for _ = 1, T.iterations do
		-- flux pass (reads d, writes flux)
		for i = 1, cellCount do
			local sc = bed[i] + depth[i]
			local ei, wi, ni, si = east[i], west[i], north[i], south[i]
			local se = if ei ~= 0 then bed[ei] + depth[ei] else seaLevel
			local sw = if wi ~= 0 then bed[wi] + depth[wi] else seaLevel
			local sn = if ni ~= 0 then bed[ni] + depth[ni] else seaLevel
			local ss = if si ~= 0 then bed[si] + depth[si] else seaLevel
			local e = fluxE[i] * damp + accel * (sc - se)
			local w = fluxW[i] * damp + accel * (sc - sw)
			local n = fluxN[i] * damp + accel * (sc - sn)
			local s = fluxS[i] * damp + accel * (sc - ss)
			if e < 0 then
				e = 0
			end
			if w < 0 then
				w = 0
			end
			if n < 0 then
				n = 0
			end
			if s < 0 then
				s = 0
			end
			fluxE[i] = e
			fluxW[i] = w
			fluxN[i] = n
			fluxS[i] = s
			local totalOut = e + w + n + s
			-- don't drain more than is available this step
			local avail = depth[i] * area
			if totalOut * dt > avail and totalOut > 0 then
				local K = avail / (totalOut * dt)
				fluxE[i] = e * K
				fluxW[i] = w * K
				fluxN[i] = n * K
				fluxS[i] = s * K
			end
		end
		-- depth pass (reads flux, writes d)
		for i = 1, cellCount do
			local ei, wi, ni, si = east[i], west[i], north[i], south[i]
			local inflow = (if ei ~= 0 then fluxW[ei] else 0)
				+ (if wi ~= 0 then fluxE[wi] else 0)
				+ (if ni ~= 0 then fluxS[ni] else 0)
				+ (if si ~= 0 then fluxN[si] else 0)
			local outflow = fluxE[i] + fluxW[i] + fluxN[i] + fluxS[i]
			local nd = depth[i] + dt * (inflow - outflow) / area
			local source = sourceFloor[i]
			if source ~= nil and nd < source then
				nd = source -- pinned source floor
			end
			if nd < 0 then
				nd = 0
			end
			depth[i] = nd
		end
	end

	-- bake outputs
	local d: { [FieldMap.CellKey]: number } = {}
	local surface: { [FieldMap.CellKey]: number } = {}
	local velX: { [FieldMap.CellKey]: number } = {}
	local velZ: { [FieldMap.CellKey]: number } = {}
	for i, key in ipairs(landList) do
		d[key] = depth[i]
		surface[key] = bed[i] + depth[i]
		velX[key] = fluxE[i] - fluxW[i]
		velZ[key] = fluxN[i] - fluxS[i]
	end
	fm.scalar["waterDepth"] = d
	fm.scalar["waterSurface"] = surface
	fm.scalar["flowVelX"] = velX
	fm.scalar["flowVelZ"] = velZ
end

function WaterSim.build(config: WorldSpec.Config, fm: FieldMap.FieldMap)
	WaterSim.carve(config, fm)
	WaterSim.solve(config, fm)
end

-- Returns (surfaceElevation, isFlowing) if under water, else nil.
function WaterSim.sample(fm: FieldMap.FieldMap, x: number, z: number): (number?, boolean)
	local T = WorldSpec.Tuning.watersim
	local depth = FieldMap.bilerpScalar(fm, "waterDepth", x, z, 0)
	if depth <= T.minRenderDepth then
		return nil, false
	end
	local surf = FieldMap.bilerpScalar(fm, "waterSurface", x, z, fm.config.seaLevel)
	local vx = FieldMap.bilerpScalar(fm, "flowVelX", x, z, 0)
	local vz = FieldMap.bilerpScalar(fm, "flowVelZ", x, z, 0)
	local flowing = (vx * vx + vz * vz) > (T.flowThreshold * T.flowThreshold)
	return surf, flowing
end

return WaterSim
