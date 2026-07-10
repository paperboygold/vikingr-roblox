--!strict
--!native

-- Hydrology — the single cached grid solve. Runs once at build; everything below
-- bakes into FieldMap faces so per-voxel reads are O(1).
--
--   priority-flood + ε (Barnes 2014)  → "elevFilled" (hydrologically correct surface)
--   D8 steepest descent                → graph "receiver" (the flow network)
--   flow accumulation (B/U additive)   → accum "flowAcc" (drainage area, streaming law)
--   accumulation threshold             → mask "river"
--   filled-above-raw + spill flatten   → mask "lake" + scalar "waterLevel" (flat per basin)
--   below sea / land-touching-sea      → mask "sea" / "coast"
--
-- route() is reused by both solve() (on elevRaw) and refine() (on eroded elevHydro).

local WorldSpec = require(script.Parent.WorldSpec)
local FieldMap = require(script.Parent.FieldMap)

local Hydrology = {}

-- ── binary min-heap keyed by elevation ───────────────────────────────────────
local Heap = {}
Heap.__index = Heap
local function newHeap()
	return setmetatable({
		n = 0,
		prio = {},
		val = {},
	}, Heap)
end
function Heap.push(self, prio: number, val: FieldMap.CellKey)
	self.n += 1
	local prios = self.prio
	local vals = self.val
	local i = self.n
	prios[i] = prio
	vals[i] = val
	while i > 1 do
		local p = i // 2
		if prios[p] <= prios[i] then
			break
		end
		prios[p], prios[i] = prios[i], prios[p]
		vals[p], vals[i] = vals[i], vals[p]
		i = p
	end
end
function Heap.pop(self): (number?, FieldMap.CellKey?)
	if self.n == 0 then
		return nil, nil
	end
	local prios = self.prio
	local vals = self.val
	local topPrio = prios[1]
	local topVal = vals[1]
	prios[1] = prios[self.n]
	vals[1] = vals[self.n]
	prios[self.n] = nil
	vals[self.n] = nil
	self.n -= 1
	local i = 1
	while true do
		local l, r, s = 2 * i, 2 * i + 1, i
		if l <= self.n and prios[l] < prios[s] then s = l end
		if r <= self.n and prios[r] < prios[s] then s = r end
		if s == i then break end
		prios[s], prios[i] = prios[i], prios[s]
		vals[s], vals[i] = vals[i], vals[s]
		i = s
	end
	return topPrio, topVal
end

-- Reset the derived fields so route() can run twice (solve then refine).
local function clearOutputs(fm: FieldMap.FieldMap)
	fm.scalar["elevFilled"] = {}
	fm.scalar["waterLevel"] = {}
	fm.scalar["basin"] = {}
	fm.graph["receiver"] = {}
	fm.accum["flowAcc"] = {}
	fm.mask["river"] = {}
	fm.mask["lake"] = {}
	fm.mask["sea"] = {}
	fm.mask["coast"] = {}
end

-- Route drainage over `srcField` (the current terrain surface). Returns stats.
function Hydrology.route(config: WorldSpec.Config, fm: FieldMap.FieldMap, srcField: string): { [string]: number }
	local T = WorldSpec.Tuning.hydrology
	local seaLevel = config.seaLevel
	local eps = T.epsilon
	local src = FieldMap.scalarField(fm, srcField)
	local topology = fm.topology
	local basis = topology.neighbors8
	local cellCount = topology.count
	local land = FieldMap.maskField(fm, "land")
	local rainfall = FieldMap.scalarField(fm, "rainfall")

	clearOutputs(fm)
	local filled: { [FieldMap.CellKey]: number } = {}

	-- 1) Priority-flood + ε. Seed every ocean cell and every grid-edge cell as an
	--    outlet, then flood inward filling depressions to their spill elevation.
	local heap = newHeap()
	local closed: { [FieldMap.CellKey]: boolean } = {}
	for key = 1, cellCount do
		local base = (key - 1) * 8
		local edge = basis[base + 1] == 0 or basis[base + 2] == 0
			or basis[base + 3] == 0 or basis[base + 4] == 0
		if land[key] ~= true or edge then
			local e = src[key] or seaLevel
			filled[key] = e
			closed[key] = true
			Heap.push(heap, e, key)
		end
	end
	while heap.n > 0 do
		local e, c = Heap.pop(heap)
		local base = ((c :: FieldMap.CellKey) - 1) * 8
		for slot = base + 1, base + 8 do
			local nk = basis[slot]
			if nk ~= 0 and not closed[nk] then
				local ne = math.max(src[nk] or seaLevel, (e :: number) + eps)
				filled[nk] = ne
				closed[nk] = true
				Heap.push(heap, ne, nk)
			end
		end
	end
	fm.scalar["elevFilled"] = filled

	-- 2) D8 receivers (steepest descent on the filled surface). ε-fill guarantees a
	--    strictly lower neighbour for every land cell → acyclic.
	local landCells: { FieldMap.CellKey } = {}
	local recv: { [FieldMap.CellKey]: FieldMap.CellKey } = {}
	local receiverGraph = fm.graph["receiver"]
	for key = 1, cellCount do
		if land[key] == true then
			landCells[#landCells + 1] = key
			local minE, minKey = math.huge, nil
			local base = (key - 1) * 8
			for slot = base + 1, base + 8 do
				local nk = basis[slot]
				if nk ~= 0 then
					local neighborE = filled[nk]
					if neighborE ~= nil and (neighborE < minE
						or (neighborE == minE and (minKey == nil or nk < minKey))) then
						minE, minKey = neighborE, nk
					end
				end
			end
			if minKey ~= nil and minE < filled[key] then
				recv[key] = minKey
				receiverGraph[key] = { minKey }
			else
				recv[key] = key -- sink (borders an outlet directly)
			end
		end
	end

	-- 3) Flow accumulation as the B/U additive fold. Self-contribution first, then
	--    process high→low so every donor is complete before it drains into receiver.
	local flowAcc = fm.accum["flowAcc"]
	for _, key in ipairs(landCells) do
		flowAcc[key] = (rainfall[key] or 0) + 0.01 -- floor keeps dry cells contributing
	end
	table.sort(landCells, function(a, b)
		return (filled[a] or 0) > (filled[b] or 0)
	end)
	for _, key in ipairs(landCells) do
		local r = recv[key]
		if r ~= key then
			flowAcc[r] = (flowAcc[r] or 0) + (flowAcc[key] or 0)
		end
	end

	-- Adaptive river threshold: channelize roughly `riverLandFraction` of the land,
	-- floored at riverAccumFloor. Robust to the absolute rainfall/flow units.
	local flowVals: { number } = {}
	for _, key in ipairs(landCells) do
		flowVals[#flowVals + 1] = flowAcc[key] or 0
	end
	table.sort(flowVals, function(a, b) return a > b end)
	local targetIdx = math.max(1, math.floor(#flowVals * T.riverLandFraction))
	local riverThreshold = math.max(T.riverAccumFloor, flowVals[targetIdx] or T.riverAccumFloor)

	-- 4) Rivers, lakes (raw), sea, coast.
	local riverCells, lakeCellsRaw = 0, 0
	for _, key in ipairs(landCells) do
		local e = src[key] or seaLevel
		local f = filled[key] or e
		if f > e + T.lakeTolerance then
			FieldMap.setMask(fm, "lake", key)
			lakeCellsRaw += 1
		elseif e > seaLevel and (flowAcc[key] or 0) >= riverThreshold then
			FieldMap.setMask(fm, "river", key)
			FieldMap.setScalar(fm, "waterLevel", key, e) -- river surface at local ground
			riverCells += 1
		end
	end

	-- sea (non-land at/below sea level) and coast (land touching non-land)
	local sea = fm.mask["sea"]
	local coast = fm.mask["coast"]
	for key = 1, cellCount do
		if land[key] ~= true then
			if (src[key] or seaLevel) <= seaLevel then
				sea[key] = true
			end
		else
			local base = (key - 1) * 8
			for slot = base + 1, base + 4 do
				local nk = basis[slot]
				if nk == 0 or land[nk] ~= true then
					coast[key] = true
					break
				end
			end
		end
	end

	-- 5) Flatten lakes: connected components (4-neigh) share one spill = min filled.
	local basin, basinSizes = FieldMap.componentLabels(fm, "lake")
	local basinSpill: { [number]: number } = {}
	for key, id in pairs(basin) do
		basinSpill[id] = math.min(basinSpill[id] or math.huge, filled[key] or math.huge)
	end
	for key, id in pairs(basin) do
		FieldMap.setScalar(fm, "waterLevel", key, basinSpill[id] or seaLevel)
		FieldMap.setScalar(fm, "basin", key, id)
	end
	local basinCount = 0
	for _ in pairs(basinSizes) do basinCount += 1 end

	return {
		landCells = #landCells,
		riverCells = riverCells,
		lakeCells = lakeCellsRaw,
		lakeBasins = basinCount,
	}
end

function Hydrology.solve(config: WorldSpec.Config, fm: FieldMap.FieldMap): { [string]: number }
	return Hydrology.route(config, fm, "elevRaw")
end

function Hydrology.refine(config: WorldSpec.Config, fm: FieldMap.FieldMap): { [string]: number }
	return Hydrology.route(config, fm, "elevHydro")
end

return Hydrology
