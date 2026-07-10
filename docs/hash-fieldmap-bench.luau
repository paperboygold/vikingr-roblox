--!strict

-- CLI microbenchmark for the FieldMap hot key shape.
--
-- Run from repo root:
--   ./docs/run-hash-fieldmap-bench.sh
--
-- It intentionally does not require Roblox services. The Hash module body is
-- loaded by dofile-compatible transformation in the shell commands used by
-- Codex, or by placing this next to a CLI loader if needed.

local Hash = Hash

local W = 112
local D = 82
local HALF_W = math.floor(W / 2)
local HALF_D = math.floor(D / 2)
local ROUNDS = 80

local function now(): number
	return os.clock()
end

local function stringKey(x: number, z: number): string
	return Hash.key({ "cell", x, z })
end

local function parseStringKey(key: string): (number, number)
	local parts = Hash.splitKey(key)
	return tonumber(parts[2]) :: number, tonumber(parts[3]) :: number
end

local function denseCoord(x: number, z: number): number
	return (x + HALF_W) * D + (z + HALF_D)
end

local function splitDenseCoord(coord: number): (number, number)
	return math.floor(coord / D) - HALF_W, (coord % D) - HALF_D
end

local function bench(name: string, fn: () -> number)
	collectgarbage("collect")
	local t0 = now()
	local checksum = fn()
	local dt = now() - t0
	print(string.format("%-24s %.6f checksum=%0.3f", name, dt, checksum))
end

bench("string-dict field", function(): number
	local scalar: { [string]: number } = {}
	local mask: { [string]: boolean } = {}
	local accum: { [string]: number } = {}
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = stringKey(x, z)
				scalar[key] = x * 0.25 + z * 0.5
				if ((x + z) % 3) == 0 then
					mask[key] = true
				end
				accum[key] = (accum[key] or 0) + 1
			end
		end
	end
	for key in pairs(mask) do
		local x, z = parseStringKey(key)
		sum += (scalar[key] or 0) + (accum[key] or 0) + x * 0.001 + z * 0.001
	end
	return sum
end)

bench("coord-table field", function(): number
	local n = W * D
	local scalar = Hash.CoordMap(n)
	local mask = Hash.CoordMap(n)
	local accum = Hash.CoordMap(n)
	local keys = table.create(n)
	local keyCount = 0
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = Hash.cellCoord(x, z)
				scalar:put(key, x * 0.25 + z * 0.5)
				if ((x + z) % 3) == 0 then
					if not mask:has(key) then
						keyCount += 1
						keys[keyCount] = key
					end
					mask:mark(key)
				end
				accum:add(key, 1)
			end
		end
	end
	for i = 1, keyCount do
		local key = keys[i]
		local x, z = Hash.splitCellCoord(key)
		sum += (scalar:get(key, 0) :: number) + accum:count(key) + x * 0.001 + z * 0.001
	end
	return sum
end)

bench("number-dict packed", function(): number
	local scalar: { [number]: number } = {}
	local mask: { [number]: boolean } = {}
	local accum: { [number]: number } = {}
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = Hash.cellCoord(x, z)
				scalar[key] = x * 0.25 + z * 0.5
				if ((x + z) % 3) == 0 then
					mask[key] = true
				end
				accum[key] = (accum[key] or 0) + 1
			end
		end
	end
	for key in pairs(mask) do
		local x, z = Hash.splitCellCoord(key)
		sum += (scalar[key] or 0) + (accum[key] or 0) + x * 0.001 + z * 0.001
	end
	return sum
end)

bench("grid-map field", function(): number
	local scalar = Hash.GridMap(HALF_W, HALF_D)
	local mask = Hash.GridMap(HALF_W, HALF_D)
	local accum = Hash.GridMap(HALF_W, HALF_D)
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = Hash.cellCoord(x, z)
				scalar[key] = x * 0.25 + z * 0.5
				if ((x + z) % 3) == 0 then
					mask[key] = true
				end
				accum[key] = (accum[key] or 0) + 1
			end
		end
	end
	for key in mask do
		local x, z = Hash.splitCellCoord(key)
		sum += (scalar[key] or 0) + (accum[key] or 0) + x * 0.001 + z * 0.001
	end
	return sum
end)

bench("number-dict dense", function(): number
	local scalar: { [number]: number } = {}
	local mask: { [number]: boolean } = {}
	local accum: { [number]: number } = {}
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = denseCoord(x, z)
				scalar[key] = x * 0.25 + z * 0.5
				if ((x + z) % 3) == 0 then
					mask[key] = true
				end
				accum[key] = (accum[key] or 0) + 1
			end
		end
	end
	for key in pairs(mask) do
		local x, z = splitDenseCoord(key)
		sum += (scalar[key] or 0) + (accum[key] or 0) + x * 0.001 + z * 0.001
	end
	return sum
end)

bench("coord-table dense", function(): number
	local n = W * D
	local scalar = Hash.CoordMap(n)
	local mask = Hash.CoordMap(n)
	local accum = Hash.CoordMap(n)
	local keys = table.create(n)
	local keyCount = 0
	local sum = 0
	for _ = 1, ROUNDS do
		for x = -HALF_W, HALF_W - 1 do
			for z = -HALF_D, HALF_D - 1 do
				local key = denseCoord(x, z)
				scalar:put(key, x * 0.25 + z * 0.5)
				if ((x + z) % 3) == 0 then
					if not mask:has(key) then
						keyCount += 1
						keys[keyCount] = key
					end
					mask:mark(key)
				end
				accum:add(key, 1)
			end
		end
	end
	for i = 1, keyCount do
		local key = keys[i]
		local x, z = splitDenseCoord(key)
		sum += (scalar:get(key, 0) :: number) + accum:count(key) + x * 0.001 + z * 0.001
	end
	return sum
end)
