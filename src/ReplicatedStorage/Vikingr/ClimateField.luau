--!strict
--!native

-- ClimateField — temperature (closed-form O(1)) and rainfall (one advection sweep,
-- then O(1) baked reads). Rainfall drives flow-accumulation weighting, marsh/biome
-- placement, and material selection. Rain shadow emerges from orographic depletion.

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)

local ClimateField = {}

-- Closed-form temperature at a cell: latitude gradient (colder toward +z) minus a
-- lapse rate with elevation. Never baked — sampled on demand.
function ClimateField.temperatureAt(config: WorldSpec.Config, elev: number, z: number): number
	local T = WorldSpec.Tuning.climate
	local halfD = math.floor(config.depth / 2)
	local lat = z / halfD -- ~[-1, 1)
	return T.baseTemp + T.latGrad * lat - T.lapse * math.max(0, elev - config.seaLevel)
end

-- One upwind→downwind advection sweep. Humidity enters over ocean and is deposited
-- as it is forced up terrain; leeward cells are left dry (rain shadow). Bakes
-- scalar "rainfall". Requires scalar "elevRaw" and mask "land" to exist.
function ClimateField.buildRainfall(config: WorldSpec.Config, fm: FieldMap.FieldMap)
	local T = WorldSpec.Tuning.climate
	local angle = WorldSpec.hashRange(config.seed, 30, T.windAngleRange[1], T.windAngleRange[2])
	local wx, wz = math.cos(angle), math.sin(angle)

	-- Upwind neighbour offset (rounded dominant wind direction).
	local ux = wx >= 0 and -1 or 1
	if math.abs(wx) < 0.4 then ux = 0 end
	local uz = wz >= 0 and -1 or 1
	if math.abs(wz) < 0.4 then uz = 0 end

	-- Gather cells and sort upwind→downwind by projection onto the wind vector.
	local cells: { { key: FieldMap.CellKey, x: number, z: number, proj: number } } = {}
	FieldMap.eachCell(fm, function(key, x, z)
		table.insert(cells, { key = key, x = x, z = z, proj = x * wx + z * wz })
	end)
	table.sort(cells, function(a, b) return a.proj < b.proj end)

	local humidity: { [FieldMap.CellKey]: number } = {}
	for _, cell in ipairs(cells) do
		local key = cell.key
		local upKey = FieldMap.cellKey(cell.x + ux, cell.z + uz)
		local isLand = FieldMap.hasMask(fm, "land", key)
		local elev = FieldMap.getScalar(fm, "elevRaw", key, config.seaLevel)

		local Hup = humidity[upKey]
		if Hup == nil then
			Hup = T.humidity0 -- entering the map from upwind: saturated ocean air
		end

		local precip: number
		local H: number
		if not isLand then
			-- over ocean: replenish moisture, negligible precipitation
			H = math.min(T.humidity0, Hup + T.replenish)
			precip = 0
		else
			local upElev = FieldMap.getScalar(fm, "elevRaw", upKey, config.seaLevel)
			local lift = math.max(0, elev - upElev) / config.maxHeight -- [0,1]
			precip = Hup * (T.baseRate + T.oroRate * lift)
			H = math.max(0, Hup - precip)
		end

		humidity[key] = H
		FieldMap.setScalar(fm, "rainfall", key, precip)
	end
end

-- O(1) bilinear read of baked rainfall.
function ClimateField.rainfallAt(fm: FieldMap.FieldMap, x: number, z: number): number
	local x0 = math.floor(x)
	local z0 = math.floor(z)
	local fx, fz = x - x0, z - z0
	local function r(cx: number, cz: number): number
		return FieldMap.getScalar(fm, "rainfall", FieldMap.cellKey(cx, cz), 0)
	end
	local r00 = r(x0, z0)
	local r10 = r(x0 + 1, z0)
	local r01 = r(x0, z0 + 1)
	local r11 = r(x0 + 1, z0 + 1)
	return WorldSpec.lerp(WorldSpec.lerp(r00, r10, fx), WorldSpec.lerp(r01, r11, fx), fz)
end

return ClimateField
