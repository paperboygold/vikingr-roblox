--!strict
--!native

-- Erosion — N synchronous double-buffered sweeps over "elevHydro" (the schedule-free
-- Web.sweep / ported Jacobi–Laplacian stencil). Each pass reads a frozen snapshot and
-- writes a fresh buffer, so a cell never sees its own half-applied update.
--
--   dz = -stream-power incision (Kstream·A^m·S^n)   -- carves valleys along flow
--        + Laplacian diffusion  (Kdiff·∇²elev)      -- hillslope smoothing (main term)
--        + deposition           (Kdep·A·(depSlope-S))-- floodplains in flat high-flow
--
-- Incision is capped so a cell can never drop below its D8 receiver → drainage stays
-- monotone and the sweep cannot oscillate. Fixed pass count → bounded one-time cost.
--
-- Requires: scalar "elevHydro" (init = elevRaw), graph "receiver", accum "flowAcc",
-- mask "land" (from Hydrology.solve).

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)

local Erosion = {}

local NB4 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

function Erosion.run(config: WorldSpec.Config, fm: FieldMap.FieldMap, passes: number)
	local T = WorldSpec.Tuning.erosion
	local seaLevel = config.seaLevel
	local dist = config.cellSize
	local floor = seaLevel + T.minElevOffset
	local ceil = config.maxHeight
	local cellKey = FieldMap.cellKey
	local receiver = fm.graph["receiver"] or {}

	for _ = 1, passes do
		local src = FieldMap.snapshot(fm, "elevHydro")
		local buf: { [FieldMap.CellKey]: number } = {}

		FieldMap.eachCell(fm, function(key, x, z)
			local here = src[key]
			if here == nil then
				return
			end
			if not FieldMap.hasMask(fm, "land", key) then
				buf[key] = here -- seabed unchanged by fluvial erosion
				return
			end

			-- receiver + slope
			local recList = receiver[key]
			local rec = (recList ~= nil and recList[1]) or key
			local recElev = src[rec] or here
			local drop = here - recElev
			local S = math.max(0, drop / dist)

			-- Laplacian over LAND neighbours only (ocean neighbours held at `here`
			-- so coasts don't collapse toward the seabed).
			local lap = 0
			for _, d in ipairs(NB4) do
				local nk = cellKey(x + d[1], z + d[2])
				local ne = (FieldMap.hasMask(fm, "land", nk) and src[nk]) or here
				lap += ne - here
			end

			local A = FieldMap.getCount(fm, "flowAcc", key)
			local incision = T.kStream * (A ^ T.mExp) * (S ^ T.nExp)
			local diffusion = T.kDiff * lap
			local deposition = T.kDep * A * math.max(0, T.depSlope - S)

			local dz = -incision + diffusion + deposition
			-- never incise below the receiver (monotone drainage, no oscillation)
			if dz < -drop then
				dz = -drop
			end
			buf[key] = math.clamp(here + dz, floor, ceil)
		end)

		FieldMap.commit(fm, "elevHydro", buf)
	end
end

return Erosion
