--!strict
--!native

-- ContinentField — closed-form macro landmass, O(1) per sample.
--
-- Hard guarantee (the gameplay requirement): >=2 large landmasses separated by a
-- wide open sea. The sea is a vertical corridor (along z, since width>depth gives
-- the widest cross-sea reach). Two Gaussian "metaball" landmasses sit west and east
-- of it. The guarantee is structural, not statistical:
--
--   * channelMask reads UNWARPED coordinates, so domain-warp can never close the lane;
--   * channelDepth is computed to strictly dominate the maximum possible land
--     potential + detail, so continentAt < 0 everywhere inside the corridor for ANY
--     seed/warp/detail.
--
-- continentAt returns a signed "continentality" C; baseElevation turns C into a
-- continuous surface with a gentle continental shelf (sub-sea) and a coastal plain
-- (shallow near-shore land slope) — no step coasts.

local WorldSpec = require(script.Parent.WorldSpec)

local ContinentField = {}

export type Center = { cx: number, cz: number, rx: number, rz: number, w: number }

export type Params = {
	x0: number,
	amp: number,
	omega: number,
	phi: number,
	wsea: number,
	shelfW: number,
	centers: { Center },
	warpAmp: number,
	warpFreq: number,
	seaBias: number,
	channelDepth: number,
	coastRough: number,
	coastRoughFreq: number,
	landHeight: number,
	pLand: number,
	cLand: number,
	shelfDrop: number,
	cShelf: number,
	maxLandPotential: number,
}

function ContinentField.paramsFromSeed(config: WorldSpec.Config): Params
	local T = WorldSpec.Tuning.continent
	local seed = config.seed
	local halfW = math.floor(config.width / 2)

	local x0 = WorldSpec.hashRange(seed, 1, T.channelX0Range[1], T.channelX0Range[2])
	local amp = WorldSpec.hashRange(seed, 2, T.channelAmpRange[1], T.channelAmpRange[2])
	local phi = WorldSpec.hash01(seed, 3, 0) * 2 * math.pi

	local xW = -WorldSpec.hashRange(seed, 4, T.centerXFrac[1], T.centerXFrac[2]) * halfW
	local zW = WorldSpec.hashRange(seed, 5, T.centerZRange[1], T.centerZRange[2])
	local xE = WorldSpec.hashRange(seed, 6, T.centerXFrac[1], T.centerXFrac[2]) * halfW
	local zE = WorldSpec.hashRange(seed, 7, T.centerZRange[1], T.centerZRange[2])

	local centers: { Center } = {
		{ cx = xW, cz = zW, rx = T.radiusX, rz = T.radiusZ, w = T.primaryWeight },
		{ cx = xE, cz = zE, rx = T.radiusX, rz = T.radiusZ, w = T.primaryWeight },
	}

	-- Secondary blobs, kept on their own side and clear of the channel corridor.
	-- (Even if one strayed in, the channelDepth guarantee below still forces sea.)
	local minMag = T.seaHalfWidth + T.shelfFalloff + T.secondaryRadius + math.abs(x0) + amp + 2
	local idx = 8
	for side = 1, 2 do
		local sign = side == 1 and -1 or 1
		local baseX = side == 1 and xW or xE
		local baseZ = side == 1 and zW or zE
		for _ = 1, T.secondaryPerSide do
			local ox = WorldSpec.hashRange(seed, idx, -18, 18)
			idx += 1
			local oz = WorldSpec.hashRange(seed, idx, -28, 28)
			idx += 1
			local bx = baseX + ox
			if sign < 0 then
				bx = math.min(bx, -minMag)
			else
				bx = math.max(bx, minMag)
			end
			table.insert(centers, {
				cx = bx,
				cz = baseZ + oz,
				rx = T.secondaryRadius,
				rz = T.secondaryRadius,
				w = T.secondaryWeight,
			})
		end
	end

	local maxLandPotential = 0
	for _, c in ipairs(centers) do
		maxLandPotential += c.w
	end

	-- The guarantee: inside the corridor (M=1), continentAt <= maxLandPotential +
	-- coastRough - seaBias - channelDepth. Force this strictly negative.
	local channelDepth = math.max(T.channelDepth, maxLandPotential + T.coastRough + 0.5)

	return {
		x0 = x0,
		amp = amp,
		omega = T.channelOmega,
		phi = phi,
		wsea = T.seaHalfWidth,
		shelfW = T.shelfFalloff,
		centers = centers,
		warpAmp = T.warpAmpMax,
		warpFreq = T.warpFreq,
		seaBias = T.seaBias,
		channelDepth = channelDepth,
		coastRough = T.coastRough,
		coastRoughFreq = T.coastRoughFreq,
		landHeight = T.landHeight,
		pLand = T.pLand,
		cLand = T.cLand,
		shelfDrop = T.shelfDrop,
		cShelf = T.cShelf,
		maxLandPotential = maxLandPotential,
	}
end

-- Low-frequency domain warp for organic coastlines. Only perturbs the metaball
-- sampling — NOT the channel mask.
function ContinentField.warp(config: WorldSpec.Config, p: Params, x: number, z: number): (number, number)
	local wx = x + p.warpAmp * math.noise(x * p.warpFreq, z * p.warpFreq, config.seed * 0.01)
	local wz = z + p.warpAmp * math.noise((x + 51) * p.warpFreq, (z - 17) * p.warpFreq, config.seed * 0.02)
	return wx, wz
end

-- Corridor mask in [0,1]: 1 inside the guaranteed-sea lane, easing to 0 past the
-- shelf band. UNWARPED coordinates — this is the structural guarantee.
function ContinentField.channelMask(p: Params, x: number, z: number): number
	local center = p.x0 + p.amp * math.sin(z * p.omega + p.phi)
	local d = math.abs(x - center)
	return 1 - WorldSpec.smootherstep(p.wsea, p.wsea + p.shelfW, d)
end

-- Signed continentality C: > 0 land, <= 0 sea. O(1).
function ContinentField.continentAt(config: WorldSpec.Config, p: Params, x: number, z: number): number
	local wx, wz = ContinentField.warp(config, p, x, z)
	local L = 0
	for _, c in ipairs(p.centers) do
		local dx = (wx - c.cx) / c.rx
		local dz = (wz - c.cz) / c.rz
		L += c.w * math.exp(-(dx * dx + dz * dz))
	end
	local M = ContinentField.channelMask(p, x, z)
	local detail = p.coastRough * math.noise(x * p.coastRoughFreq, z * p.coastRoughFreq, config.seed * 0.017)
	return L - p.seaBias - p.channelDepth * M + detail
end

-- Continentality → continuous surface elevation (studs). Shelf below sea, coastal
-- plain above — both gentle, so coasts never step.
function ContinentField.baseElevation(config: WorldSpec.Config, p: Params, C: number): number
	local seaLevel = config.seaLevel
	if C > 0 then
		local t = WorldSpec.clamp01(C / p.cLand)
		return seaLevel + p.landHeight * (t ^ p.pLand)
	end

	local t = -C
	local shelfBottom = seaLevel - p.shelfDrop
	if t <= p.cShelf then
		return seaLevel - p.shelfDrop * WorldSpec.smoothstep(0, p.cShelf, t)
	end
	local deep = seaLevel - config.waterDepth
	return WorldSpec.lerp(shelfBottom, deep, WorldSpec.smoothstep(p.cShelf, p.cShelf * 2.5, t))
end

-- "land" (solid), "shelf" (voxelizable seabed), or "deepSea" (flat water fill).
function ContinentField.classify(config: WorldSpec.Config, p: Params, x: number, z: number): string
	local C = ContinentField.continentAt(config, p, x, z)
	if C > 0 then
		return "land"
	elseif C > -p.cShelf then
		return "shelf"
	end
	return "deepSea"
end

return ContinentField
