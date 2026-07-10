--!strict
--!native

-- ReliefField — closed-form elevation, O(1) per sample.
--
-- elevation = base(prediction) + envelope * peakRelief * residual
--   base      : ContinentField.baseElevation(C) — the smooth macro surface (shelf/plain)
--   envelope  : coastPlainEnvelope(C) * uplift — zero near the coast, growing inland,
--               so there is ALWAYS a coastal plain before any mountains
--   residual  : a ridged multifractal in [0,1] — the ONLY multi-octave noise, framed
--               as the scale-invariant residual on the prediction (seed=prediction+U)
--
-- This replaces WorldSpec.heightFor's noise-sum + region mountainBias, which is what
-- produced instant coast→mountain and pancake interiors.

local WorldSpec = require(script.Parent.WorldSpec)
local ContinentField = require(script.Parent.ContinentField)

local ReliefField = {}

export type Params = {
	beltDirX: number,
	beltDirZ: number,
	beltFreq: number,
	beltThreshold: number,
	orogenyMix: number,
	cPlain: number,
	cRamp: number,
	peakRelief: number,
}

function ReliefField.paramsFromSeed(config: WorldSpec.Config): Params
	local T = WorldSpec.Tuning.relief
	local angle = WorldSpec.hashRange(config.seed, 20, T.beltAxisAngleRange[1], T.beltAxisAngleRange[2])
	return {
		beltDirX = math.cos(angle),
		beltDirZ = math.sin(angle),
		beltFreq = T.beltFreq,
		beltThreshold = T.beltThreshold,
		orogenyMix = T.orogenyMix,
		cPlain = T.cPlain,
		cRamp = T.cRamp,
		peakRelief = T.peakRelief,
	}
end

-- Zero until continentality passes cPlain, then ramps to 1 — the coastal-plain knob.
function ReliefField.coastPlainEnvelope(rp: Params, C: number): number
	return WorldSpec.smoothstep(rp.cPlain, rp.cPlain + rp.cRamp, C)
end

-- Tectonic uplift potential in [0,1]: broad interior swell blended with mountain
-- belts running parallel to a seed-chosen tectonic axis.
function ReliefField.upliftAt(config: WorldSpec.Config, rp: Params, C: number, x: number, z: number): number
	local interior = WorldSpec.smoothstep(0, 1.0, C)
	-- Rotate into axis coordinates; ridges vary fast ACROSS the axis, slow ALONG it.
	local along = x * rp.beltDirX + z * rp.beltDirZ
	local across = -x * rp.beltDirZ + z * rp.beltDirX
	local ridged = 1 - math.abs(math.noise(across * rp.beltFreq, along * rp.beltFreq * 0.3, config.seed * 0.033))
	local belt = WorldSpec.smoothstep(rp.beltThreshold, 1.0, ridged)
	return WorldSpec.clamp01(interior * (1 - rp.orogenyMix) + belt * rp.orogenyMix)
end

-- Ridged multifractal residual in [0,1] — self-similar ridge/valley hierarchy.
function ReliefField.reliefResidualAt(config: WorldSpec.Config, x: number, z: number): number
	local T = WorldSpec.Tuning.relief
	local sum = 0
	local norm = 0
	local amp = 1
	local freq = T.residualF0
	for k = 0, T.residualOctaves - 1 do
		local n = math.noise(x * freq, z * freq, config.seed * (0.05 + k * 0.017))
		sum += amp * (1 - math.abs(n))
		norm += amp
		amp *= T.residualGain
		freq *= T.residualLacunarity
	end
	return sum / norm
end

-- Full elevation at a cell, given precomputed continentality C.
function ReliefField.elevationAt(
	config: WorldSpec.Config,
	cp: ContinentField.Params,
	rp: Params,
	x: number,
	z: number,
	C: number
): number
	local base = ContinentField.baseElevation(config, cp, C)
	if C <= 0 then
		-- Seabed: the SAME ridged-multifractal field as land relief, reused signed
		-- (recentred [0,1]->[-1,1]) so it gives both ridges/seamounts and canyons/trenches —
		-- one self-similar field read on either side of the coastline, not a flat slab.
		-- Gated to start where the shelf finishes sinking (gentle shelf, textured beyond),
		-- and clamped so it can never breach the surface (the sea-corridor guarantee holds).
		local T = WorldSpec.Tuning.relief
		local t = -C
		local env = WorldSpec.smoothstep(T.underwaterRampT0, T.underwaterRampT1, t)
		local signed = ReliefField.reliefResidualAt(config, x, z) * 2 - 1
		local elev = base + env * T.peakReliefUnderwater * signed
		return math.clamp(
			elev,
			config.seaLevel - config.waterDepth - T.peakReliefUnderwater,
			config.seaLevel - T.seabedClearance
		)
	end
	local env = ReliefField.coastPlainEnvelope(rp, C) * ReliefField.upliftAt(config, rp, C, x, z)
	local R = ReliefField.reliefResidualAt(config, x, z)
	local elev = base + env * rp.peakRelief * R
	return math.clamp(elev, config.seaLevel, config.maxHeight)
end

return ReliefField
