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
	fm.mask["waterDomain"] = {}
	fm.mask["reservoirBoundary"] = {}
	local waterDomain = fm.mask["waterDomain"]
	local reservoirBoundary = fm.mask["reservoirBoundary"]

	-- downstream order (highest filled first)
	local rivers = FieldMap.maskKeys(fm, "river")
	table.sort(rivers, function(a, c) return (filled[a] or 0) > (filled[c] or 0) end)

	-- pass 1: monotone descending centerline, reaching below sea at the mouth
	local maxAllowedSurface: { [FieldMap.CellKey]: number } = {}
	local centerSurface: { [FieldMap.CellKey]: number } = {}
	local centerBed: { [FieldMap.CellKey]: number } = {}
	for _, key in ipairs(rivers) do
		local Q = FieldMap.getCount(fm, "flowAcc", key)
		local depth = channelDepth(config, Q)
		local surface = math.min(b[key] or seaLevel, maxAllowedSurface[key] or math.huge)
		local rec = receiver[key]
		local recKey = rec ~= nil and rec[1] or nil
		local toSea = recKey == nil or not land[recKey]
		if toSea then
			-- The river and ocean share one free surface at the mouth. Depth belongs below
			-- that surface; lowering the surface itself creates a visible notch or dam.
			surface = seaLevel
			depth = math.max(depth, T.mouthDrop)
			reservoirBoundary[key] = true
		end
		local bed = surface - depth
		centerSurface[key] = surface
		centerBed[key] = bed
		b[key] = math.min(b[key] or math.huge, bed)
		waterDomain[key] = true
		if recKey ~= nil and land[recKey] then
			maxAllowedSurface[recKey] = math.min(maxAllowedSurface[recKey] or math.huge, surface - T.carveDrop)
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
		local surface = centerSurface[key]
		local R = math.max(W * 0.5, T.carveMinRadius)
		local rc = math.ceil(R / cellSize)
		for dx = -rc, rc do
			for dz = -rc, rc do
				local nx, nz = cx + dx, cz + dz
				if FieldMap.inBounds(fm, nx, nz) then
					local d = math.sqrt((dx * cellSize) ^ 2 + (dz * cellSize) ^ 2)
					if d < R then
						local nk = FieldMap.cellKey(nx, nz)
						if land[nk] then
							-- parabola: bed at centre → bed+depth at the bank
							local target = bed + depth * (d / R) ^ 2
							if target < (b[nk] or math.huge) then
								b[nk] = target
							end
							if target < surface then
								waterDomain[nk] = true
							end
						end
					end
				end
			end
		end
	end

	-- Lake basins are part of the same admissible water domain as channels.
	for _, key in ipairs(FieldMap.maskKeys(fm, "lake")) do
		waterDomain[key] = true
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

	-- The relaxation is many sweeps over the same topology. Only carved channel and lake
	-- cells participate. `0` is a sea sink; `-1` is a solid bank with zero face flux.
	local domainList = FieldMap.maskKeys(fm, "waterDomain")
	local cellCount = #domainList
	local indexByKey: { [FieldMap.CellKey]: number } = {}
	local xByIndex: { number } = table.create(cellCount)
	local zByIndex: { number } = table.create(cellCount)
	local bed: { number } = table.create(cellCount)
	local depth: { number } = table.create(cellCount)
	local sourceFloor: { number? } = table.create(cellCount)
	local fixedSurface: { number? } = table.create(cellCount)
	local reservoirBoundary = fm.mask["reservoirBoundary"] or {}
	for i, key in ipairs(domainList) do
		indexByKey[key] = i
		local cx, cz = FieldMap.parseKey(key)
		xByIndex[i] = cx
		zByIndex[i] = cz
		bed[i] = b[key] or seaLevel
		if reservoirBoundary[key] then
			fixedSurface[i] = seaLevel
			depth[i] = math.max(0, seaLevel - bed[i])
		else
			local source = seed[key]
			sourceFloor[i] = source
			depth[i] = source or 0
		end
	end

	local east: { number } = table.create(cellCount)
	local west: { number } = table.create(cellCount)
	local north: { number } = table.create(cellCount)
	local south: { number } = table.create(cellCount)
	local land = fm.mask["land"] or {}
	local function neighborIndex(x: number, z: number): number
		if not FieldMap.inBounds(fm, x, z) then
			return 0
		end
		local key = FieldMap.cellKey(x, z)
		local index = indexByKey[key]
		if index ~= nil then
			return index
		end
		if not land[key] then
			return 0
		end
		return -1
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
			local se = if ei > 0 then bed[ei] + depth[ei] elseif ei == 0 then seaLevel else sc
			local sw = if wi > 0 then bed[wi] + depth[wi] elseif wi == 0 then seaLevel else sc
			local sn = if ni > 0 then bed[ni] + depth[ni] elseif ni == 0 then seaLevel else sc
			local ss = if si > 0 then bed[si] + depth[si] elseif si == 0 then seaLevel else sc
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
			local inflow = (if ei > 0 then fluxW[ei] else 0)
				+ (if wi > 0 then fluxE[wi] else 0)
				+ (if ni > 0 then fluxS[ni] else 0)
				+ (if si > 0 then fluxN[si] else 0)
			local outflow = fluxE[i] + fluxW[i] + fluxN[i] + fluxS[i]
			local nd = depth[i] + dt * (inflow - outflow) / area
			local boundarySurface = fixedSurface[i]
			if boundarySurface ~= nil then
				-- A reservoir boundary prescribes exterior potential, so the boundary
				-- cell cannot accumulate above or drain below that equilibrium surface.
				nd = math.max(0, boundarySurface - bed[i])
			else
				local source = sourceFloor[i]
				if source ~= nil and nd < source then
					nd = source -- pinned source floor
				end
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
	for i, key in ipairs(domainList) do
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
	local x0, z0 = math.floor(x), math.floor(z)
	local fx, fz = x - x0, z - z0
	local w00 = (1 - fx) * (1 - fz)
	local w10 = fx * (1 - fz)
	local w01 = (1 - fx) * fz
	local w11 = fx * fz
	local k00 = FieldMap.cellKey(x0, z0)
	local k10 = FieldMap.cellKey(x0 + 1, z0)
	local k01 = FieldMap.cellKey(x0, z0 + 1)
	local k11 = FieldMap.cellKey(x0 + 1, z0 + 1)
	local depths = fm.scalar["waterDepth"] or {}
	local d00, d10 = depths[k00] or 0, depths[k10] or 0
	local d01, d11 = depths[k01] or 0, depths[k11] or 0
	local depth = d00 * w00 + d10 * w10 + d01 * w01 + d11 * w11
	if depth <= 0 then
		return nil, false
	end

	-- Normalize potential over wet support. Dry corners contribute zero depth but no
	-- artificial exterior potential, so a flat lake remains flat up to its wet/dry face.
	local surfaces = fm.scalar["waterSurface"] or {}
	local sw00, sw10 = if d00 > 0 then w00 else 0, if d10 > 0 then w10 else 0
	local sw01, sw11 = if d01 > 0 then w01 else 0, if d11 > 0 then w11 else 0
	local wetWeight = sw00 + sw10 + sw01 + sw11
	local surf = (
		(surfaces[k00] or fm.config.seaLevel) * sw00
		+ (surfaces[k10] or fm.config.seaLevel) * sw10
		+ (surfaces[k01] or fm.config.seaLevel) * sw01
		+ (surfaces[k11] or fm.config.seaLevel) * sw11
	) / wetWeight
	local velX = fm.scalar["flowVelX"] or {}
	local velZ = fm.scalar["flowVelZ"] or {}
	local vx = (velX[k00] or 0) * w00 + (velX[k10] or 0) * w10
		+ (velX[k01] or 0) * w01 + (velX[k11] or 0) * w11
	local vz = (velZ[k00] or 0) * w00 + (velZ[k10] or 0) * w10
		+ (velZ[k01] or 0) * w01 + (velZ[k11] or 0) * w11
	local flowing = (vx * vx + vz * vz) > (T.flowThreshold * T.flowThreshold)
	return surf, flowing
end

return WaterSim
