--!strict
--!native

-- WaterField — turns the drainage network into a CONTINUOUS, discharge-widened water
-- surface, so rivers read as rivers instead of per-cell diagonal blocks.
--
-- The width/depth come from hydraulic geometry (W ∝ √Q, D ∝ Q^0.4) — the closed-form
-- steady state of the shallow-water equations, so it is O(1) per cell with no iteration
-- (the mobile-safe baseline; the dynamic flux sweep is a later, measured option).
--
-- Continuity trick: each channel cell "stamps" a signed inside-field over a disc of its
-- half-width. `riverInside = W/2 - distanceToChannel` is positive inside the channel,
-- ~0 at the banks, negative outside — a smooth field that bilerps cleanly at voxel
-- resolution, so the rendered water footprint has no diagonal gaps and follows the real
-- channel width. Nearest/widest channel wins (max).
--
-- Baked fields (all scalar/B):
--   riverInside  : signed channel membership (studs); > 0 ⇒ under river water
--   riverSurface : water-surface elevation at that point
--   riverDepth   : channel depth (bed = surface - depth)
--   flowVelX/Z   : unit-ish flow direction × speed (for the future animated surface)

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)

local WaterField = {}

WaterField.INSIDE_DEFAULT = -1e6 -- sentinel: far outside any channel

local function discharge(fm: FieldMap.FieldMap, key: FieldMap.CellKey): number
	return FieldMap.getCount(fm, "flowAcc", key)
end

function WaterField.build(config: WorldSpec.Config, fm: FieldMap.FieldMap)
	local T = WorldSpec.Tuning.water
	local cellSize = config.cellSize
	local receiver = fm.graph["receiver"] or {}

	-- fresh output fields
	fm.scalar["riverInside"] = {}
	fm.scalar["riverSurface"] = {}
	fm.scalar["riverDepth"] = {}
	fm.scalar["flowVelX"] = {}
	fm.scalar["flowVelZ"] = {}

	for _, key in ipairs(FieldMap.maskKeys(fm, "river")) do
		local cx, cz = FieldMap.parseKey(key)
		local Q = math.max(discharge(fm, key), 0)
		local W = math.clamp(T.widthCoeff * Q ^ T.widthExp, T.minWidth, T.maxWidth)
		local D = math.clamp(T.depthCoeff * Q ^ T.depthExp, T.minDepth, T.maxDepth)
		local ground = FieldMap.getScalar(fm, "elevHydro", key, config.seaLevel)
		local surf = ground - T.surfaceDrop

		-- flow direction from the D8 receiver (downstream)
		local recList = receiver[key]
		if recList ~= nil and recList[1] ~= nil then
			local rx, rz = FieldMap.parseKey(recList[1])
			local dx, dz = rx - cx, rz - cz
			local mag = math.max(1e-6, math.sqrt(dx * dx + dz * dz))
			FieldMap.setScalar(fm, "flowVelX", key, dx / mag)
			FieldMap.setScalar(fm, "flowVelZ", key, dz / mag)
		end

		-- stamp a disc of radius W/2 + margin
		local R = W * 0.5 + T.bankMargin
		local rc = math.ceil(R / cellSize)
		for dx = -rc, rc do
			for dz = -rc, rc do
				local nx, nz = cx + dx, cz + dz
				if FieldMap.inBounds(fm, nx, nz) then
					local d = math.sqrt((dx * cellSize) ^ 2 + (dz * cellSize) ^ 2)
					if d <= R then
						local nk = FieldMap.cellKey(nx, nz)
						local inside = W * 0.5 - d
						if inside > FieldMap.getScalar(fm, "riverInside", nk, WaterField.INSIDE_DEFAULT) then
							FieldMap.setScalar(fm, "riverInside", nk, inside)
							FieldMap.setScalar(fm, "riverSurface", nk, surf)
							FieldMap.setScalar(fm, "riverDepth", nk, D)
						end
					end
				end
			end
		end
	end
end

-- Sample the river at a (fractional) cell coordinate. Returns nil if dry, else
-- (surfaceElevation, bedElevation).
function WaterField.sampleRiver(fm: FieldMap.FieldMap, x: number, z: number): (number?, number?)
	local inside = FieldMap.bilerpScalar(fm, "riverInside", x, z, WaterField.INSIDE_DEFAULT)
	if inside <= 0 then
		return nil, nil
	end
	local surf = FieldMap.bilerpScalar(fm, "riverSurface", x, z, fm.config.seaLevel)
	local depth = FieldMap.bilerpScalar(fm, "riverDepth", x, z, 0)
	return surf, surf - depth
end

return WaterField
