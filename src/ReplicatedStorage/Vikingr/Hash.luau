--!strict
--!native

-- Hash — Luau mirror of ../fold/hashtrinity.
--
-- The important shape is not "a Lua dictionary with helper functions"; it is one
-- deterministic address table with one mutator (`insertWith`) and four merge
-- faces. `Table` stores keys for exact opaque reads, `CoordMap` regenerates
-- integer coordinate keys from the address, and `FreqMap` keeps only the folded
-- coordinate for NB/count/dedup style work.

local Hash = {}

Hash.SEP = "\31"

export type TableMap = { [any]: any }
export type MergeFn = (any, any) -> any

local PHI32 = 0x9E3779B9
local FNV32 = 0x811C9DC5
local FNV_PRIME32 = 0x01000193
local U32 = 4294967296
local U16 = 65536
local EMPTY = -1
local TOMB = -2
local LINEAR_G = 8

local function u32(n: number): number
	return n % U32
end

local function imul32(a: number, b: number): number
	a = u32(a)
	b = u32(b)
	local al = a % U16
	local ah = math.floor(a / U16)
	local bl = b % U16
	local bh = math.floor(b / U16)
	return (al * bl + ((ah * bl + al * bh) % U16) * U16) % U32
end

local function rshift32(n: number, bits: number): number
	return bit32.rshift(u32(n), bits)
end

local function band32(a: number, b: number): number
	return bit32.band(u32(a), u32(b))
end

local function bxor32(a: number, b: number): number
	return bit32.bxor(u32(a), u32(b))
end

local function bitsForSlots(slots: number): number
	local n = math.max(8, math.ceil(slots))
	local bits = 3
	local cap = 8
	while cap < n do
		bits += 1
		cap *= 2
	end
	return bits
end

local function clampCoord(coord: number): number
	coord = u32(coord)
	if coord >= U32 - 2 then
		return U32 - 3
	end
	return coord
end

local function foldString(text: string): number
	local h = bxor32(FNV32, #text)
	for i = 1, #text do
		h = imul32(bxor32(h, string.byte(text, i)), FNV_PRIME32)
	end
	return clampCoord(h)
end

local function foldKey(key: any): number
	local kind = typeof(key)
	if kind == "number" then
		return clampCoord(key)
	elseif kind == "string" then
		return foldString(key)
	elseif kind == "boolean" then
		return if key then 1 else 0
	end
	return foldString(tostring(key))
end

local function keyMatches(stored: any, query: any): boolean
	return stored == query
end

local AddressTable: any = {}
AddressTable.__index = AddressTable
local GridMap = {}
GridMap.__index = function(rawSelf, key)
	local self: any = rawSelf
	local method = GridMap[key]
	if method ~= nil then
		return method
	end
	if typeof(key) ~= "number" then
		return rawget(self, key)
	end
	local idx = self:_index(key)
	if idx ~= nil then
		return self._vals[idx]
	end
	return self._extra[key]
end
GridMap.__newindex = function(rawSelf, key, value)
	local self: any = rawSelf
	if typeof(key) ~= "number" then
		rawset(self, key, value)
		return
	end

	local idx = self:_index(key)
	if idx ~= nil then
		local old = self._vals[idx]
		if old == nil and value ~= nil then
			self._len += 1
			self._keys[idx] = key
		elseif old ~= nil and value == nil then
			self._len -= 1
			self._keys[idx] = nil
		end
		self._vals[idx] = value
		return
	end

	local old = self._extra[key]
	if old == nil and value ~= nil then
		self._extraLen += 1
	elseif old ~= nil and value == nil then
		self._extraLen -= 1
	end
	self._extra[key] = value
end
GridMap.__iter = function(rawSelf)
	local self: any = rawSelf
	return GridMap.iter(self)
end

type AddressTableRecord = {
	_coords: { number },
	_keys: { any },
	_vals: { any },
	_bits: number,
	_len: number,
	_tombs: number,
	_storeKeys: boolean,
	_exact: boolean,
}

export type AddressTable = AddressTableRecord
export type GridMap = any

local function withBits(bits: number, storeKeys: boolean, exact: boolean): AddressTable
	local cap = 2 ^ bits
	local coords = table.create(cap, EMPTY)
	local vals = table.create(cap)
	local keys = table.create(cap)
	return setmetatable({
		_coords = coords,
		_keys = keys,
		_vals = vals,
		_bits = bits,
		_len = 0,
		_tombs = 0,
		_storeKeys = storeKeys,
		_exact = exact,
	}, AddressTable) :: any
end

function AddressTable._home(self: any, coord: number): number
	local cap = #self._coords
	if coord < cap then
		return coord + 1
	end
	local product = imul32(coord, PHI32)
	return rshift32(product, 32 - self._bits) + 1
end

function AddressTable._descend(self: any, coord: number, step: number): number
	local cap = #self._coords
	if step < LINEAR_G then
		return ((self:_home(coord) - 1 + step) % cap) + 1
	end

	local bits = self._bits
	local p = imul32(coord, PHI32)
	local digit = step - LINEAR_G + 1
	local used = bits * (digit + 1)
	if used <= 32 then
		return band32(rshift32(p, 32 - used), cap - 1) + 1
	end

	local full = math.floor(32 / bits)
	local tailShift = 32 - bits * full
	return ((rshift32(p, tailShift) + (digit - full) + 1) % cap) + 1
end

function AddressTable._probe(self: any, coord: number, key: any?): (number, boolean)
	local i = self:_home(coord)
	local step = 0
	while true do
		local sc = self._coords[i]
		if sc == coord then
			local keys = self._keys :: { any }
			if not (self._exact and self._storeKeys) or keyMatches(keys[i], key) then
				return i, true
			end
		elseif sc == EMPTY then
			return i, false
		end
		step += 1
		if step > #self._coords + 64 then
			error("Hash probe did not terminate")
		end
		i = self:_descend(coord, step)
	end
end

function AddressTable._resize(self: any, bits: number)
	local oldCoords = self._coords
	local oldKeys = self._keys
	local oldVals = self._vals
	local fresh = withBits(bits, self._storeKeys, self._exact)

	for i, coord in ipairs(oldCoords) do
		if coord ~= EMPTY and coord ~= TOMB then
			local key = if self._storeKeys then oldKeys[i] else nil
			local j = AddressTable._probe(fresh, coord, key)
			fresh._coords[j] = coord
			fresh._vals[j] = oldVals[i]
			if self._storeKeys then
				fresh._keys[j] = oldKeys[i]
			end
			fresh._len += 1
		end
	end

	self._coords = fresh._coords
	self._keys = fresh._keys
	self._vals = fresh._vals
	self._bits = fresh._bits
	self._len = fresh._len
	self._tombs = 0
end

function AddressTable._ensureRoom(self: any)
	local cap = #self._coords
	if (self._len + self._tombs + 1) * 8 < cap * 7 then
		return
	end
	if (self._len + 1) * 8 >= cap * 7 then
		self:_resize(self._bits + 1)
	else
		self:_resize(self._bits)
	end
end

function AddressTable.insertWith(self: any, key: any, value: any, mergeFn: MergeFn): AddressTable
	self:_ensureRoom()
	local coord = foldKey(key)
	local i, found = self:_probe(coord, key)

	if found then
		self._vals[i] = mergeFn(value, self._vals[i])
	else
		self._coords[i] = coord
		self._vals[i] = value
		if self._storeKeys then
			self._keys[i] = key
		end
		self._len += 1
	end

	return self
end

function AddressTable.put(self: any, key: any, value: any): AddressTable
	return self:insertWith(key, value, Hash.setv)
end

function AddressTable.mark(self: any, key: any): AddressTable
	return self:insertWith(key, true, Hash.keep)
end

function AddressTable.add(self: any, key: any, value: number): AddressTable
	return self:insertWith(key, value, Hash.count)
end

function AddressTable.push(self: any, key: any, value: any): AddressTable
	return self:insertWith(key, value, Hash.link)
end

function AddressTable.get(self: any, key: any, defaultValue: any?): any
	local coord = foldKey(key)
	local i, found = self:_probe(coord, key)
	if not found then
		return defaultValue
	end
	return self._vals[i]
end

function AddressTable.getExact(self: any, key: any, defaultValue: any?): any
	return self:get(key, defaultValue)
end

function AddressTable.has(self: any, key: any): boolean
	return self:get(key, false) == true
end

function AddressTable.count(self: any, key: any): number
	return self:get(key, 0) :: number
end

function AddressTable.neighbors(self: any, key: any): { any }
	return self:get(key, {}) :: { any }
end

function AddressTable.remove(self: any, key: any): any?
	local coord = foldKey(key)
	local i, found = self:_probe(coord, key)
	if not found then
		return nil
	end
	local old = self._vals[i]
	self._coords[i] = TOMB
	self._keys[i] = nil
	self._vals[i] = nil
	self._len -= 1
	self._tombs += 1
	return old
end

function AddressTable.len(self: any): number
	return self._len
end

function AddressTable.capacity(self: any): number
	return #self._coords
end

function AddressTable.isEmpty(self: any): boolean
	return self._len == 0
end

function AddressTable.iter(self: any, fn: (any, any) -> ())
	for i, coord in ipairs(self._coords) do
		if coord ~= EMPTY and coord ~= TOMB then
			local key = if self._storeKeys then self._keys[i] else coord
			fn(key, self._vals[i])
		end
	end
end

function AddressTable.encircle<A>(self: any, identity: A, residual: (any) -> A, combine: (A, A) -> A): A
	local acc = identity
	for i, coord in ipairs(self._coords) do
		if coord ~= EMPTY and coord ~= TOMB then
			acc = combine(acc, residual(self._vals[i]))
		end
	end
	return acc
end

function AddressTable.fuse(self: any, other: AddressTable, mergeFn: MergeFn): AddressTable
	AddressTable.iter(other, function(key: any, value: any)
		self:insertWith(key, value, mergeFn)
	end)
	return self
end

function AddressTable.toDict(self: any): TableMap
	local out: TableMap = {}
	self:iter(function(key: any, value: any)
		out[key] = value
	end)
	return out
end

function Hash.Table(capacity: number?): AddressTable
	return withBits(bitsForSlots(math.ceil((capacity or 8) * 8 / 7)), true, true)
end

function Hash.CoordMap(capacity: number?): AddressTable
	return withBits(bitsForSlots(math.ceil((capacity or 8) * 8 / 7)), false, false)
end

function Hash.FreqMap(capacity: number?): AddressTable
	return withBits(bitsForSlots(math.ceil((capacity or 8) * 3 / 2)), false, false)
end

function Hash.GridMap(halfW: number, halfD: number): GridMap
	local width = halfW * 2
	local depth = halfD * 2
	return setmetatable({
		_hashGrid = true,
		_halfW = halfW,
		_halfD = halfD,
		_width = width,
		_depth = depth,
		_cap = width * depth,
		_vals = table.create(width * depth),
		_keys = table.create(width * depth),
		_extra = {},
		_len = 0,
		_extraLen = 0,
	}, GridMap)
end

function GridMap._index(self: any, key: number): number?
	local x, z = Hash.splitCellCoord(key)
	local ix = x + self._halfW
	local iz = z + self._halfD
	if ix < 0 or ix >= self._width or iz < 0 or iz >= self._depth then
		return nil
	end
	return ix * self._depth + iz + 1
end

function GridMap.len(self: any): number
	return self._len + self._extraLen
end

function GridMap.clone(self: any): GridMap
	local out = Hash.GridMap(self._halfW, self._halfD)
	for i = 1, self._cap do
		local value = self._vals[i]
		if value ~= nil then
			out._vals[i] = value
			out._keys[i] = self._keys[i]
			out._len += 1
		end
	end
	for key, value in pairs(self._extra) do
		out._extra[key] = value
		out._extraLen += 1
	end
	return out
end

function GridMap.iter(self: any): () -> (number?, any?)
	local i = 0
	local extraKey = nil
	local inExtra = false
	return function(): (number?, any?)
		if not inExtra then
			while i < self._cap do
				i += 1
				local value = self._vals[i]
				if value ~= nil then
					return self._keys[i], value
				end
			end
			inExtra = true
		end
		local key, value = next(self._extra, extraKey)
		extraKey = key
		return key, value
	end
end

function Hash.coord(key: any): number
	return foldKey(key)
end

function Hash.key(parts: { any }): string
	local out = ""
	for i, part in ipairs(parts) do
		if i > 1 then
			out ..= Hash.SEP
		end
		out ..= tostring(part)
	end
	return out
end

function Hash.cellCoord(x: number, z: number): number
	-- Reversible signed pairing. Near-origin grid cells map to small integers,
	-- so Luau's native table array path can carry the hot FieldMap surface.
	local a = if x >= 0 then 2 * x else -2 * x - 1
	local b = if z >= 0 then 2 * z else -2 * z - 1
	if a >= b then
		return a * a + a + b
	end
	return a + b * b
end

function Hash.splitCellCoord(coord: number): (number, number)
	local q = math.floor(math.sqrt(coord))
	local l = coord - q * q
	local a: number
	local b: number
	if l < q then
		a = l
		b = q
	else
		a = q
		b = l - q
	end
	local x = if a % 2 == 0 then a / 2 else -(a + 1) / 2
	local z = if b % 2 == 0 then b / 2 else -(b + 1) / 2
	return x, z
end

function Hash.splitKey(key: string): { string }
	return string.split(key, Hash.SEP)
end

function Hash.keep(newValue: boolean, oldValue: boolean): boolean
	return newValue or oldValue
end

function Hash.setv(newValue: any, _oldValue: any): any
	return newValue
end

function Hash.count(newValue: number, oldValue: number): number
	return newValue + oldValue
end

function Hash.link(newValue: any, oldValue: { any }): { any }
	if typeof(oldValue) ~= "table" then
		oldValue = {}
	end
	if typeof(newValue) == "table" then
		for _, value in ipairs(newValue) do
			table.insert(oldValue, value)
		end
	else
		table.insert(oldValue, newValue)
	end
	return oldValue
end

function Hash.merge(faceName: string): MergeFn
	if faceName == "keep" then
		return Hash.keep
	elseif faceName == "set" or faceName == "setv" then
		return Hash.setv
	elseif faceName == "count" then
		return Hash.count
	elseif faceName == "link" then
		return Hash.link
	end
	error("unknown hash face: " .. tostring(faceName))
end

function Hash.identity(faceName: string): any
	if faceName == "keep" then
		return false
	elseif faceName == "count" then
		return 0
	elseif faceName == "link" then
		return {}
	end
	return nil
end

-- Compatibility surface for existing Vikingr modules. These are still plain
-- Lua dictionaries; new hot code should prefer Hash.Table/CoordMap/FreqMap.
function Hash.put(mergeFn: MergeFn, key: any, value: any, target: TableMap): TableMap
	if target[key] ~= nil then
		target[key] = mergeFn(value, target[key])
	else
		target[key] = value
	end
	return target
end

function Hash.cloneMap(target: TableMap): TableMap
	if (target :: any)._hashGrid == true then
		return (target :: any):clone()
	end
	return table.clone(target)
end

function Hash.lookup(target: TableMap, key: any, defaultValue: any?): any
	local value = target[key]
	if value == nil then
		return defaultValue
	end
	return value
end

function Hash.has(target: TableMap, key: any): boolean
	return target[key] ~= nil
end

function Hash.iterArray<T, A>(items: { T }, acc: A, fn: (A, T) -> A): A
	for _, item in ipairs(items) do
		acc = fn(acc, item)
	end
	return acc
end

function Hash.iterDict<A>(items: TableMap, acc: A, fn: (A, any, any) -> A): A
	if (items :: any)._hashGrid == true then
		for key, value in (items :: any) do
			acc = fn(acc, key, value)
		end
		return acc
	end
	for key, value in pairs(items) do
		acc = fn(acc, key, value)
	end
	return acc
end

function Hash.countKeys(items: TableMap): number
	if (items :: any)._hashGrid == true then
		return (items :: any):len()
	end
	return Hash.iterDict(items, 0, function(acc: number, _key: any, _value: any): number
		return acc + 1
	end)
end

function Hash.reduceDict<A>(items: TableMap, acc: A, fn: (A, any, any) -> A): A
	return Hash.iterDict(items, acc, fn)
end

function Hash.topK<T>(items: { T }, k: number, less: (T, T) -> boolean): { T }
	local sorted = table.clone(items)
	table.sort(sorted, less)
	local limit = math.min(k, #sorted)
	local out = table.create(limit)
	for i = 1, limit do
		out[i] = sorted[i]
	end
	return out
end

function Hash.maxBy<T>(items: { T }, score: (T) -> number): (T?, number?)
	local bestItem: T? = nil
	local bestScore = -math.huge
	for _, item in ipairs(items) do
		local s = score(item)
		if bestItem == nil or s > bestScore then
			bestItem = item
			bestScore = s
		end
	end
	if bestItem == nil then
		return nil, nil
	end
	return bestItem, bestScore
end

function Hash.argminPair<A, B>(
	left: { A },
	right: { B },
	score: (A, B) -> number?
): (A?, B?, number?)
	local bestA: A? = nil
	local bestB: B? = nil
	local bestScore = math.huge
	for _, a in ipairs(left) do
		for _, b in ipairs(right) do
			local s = score(a, b)
			if s ~= nil and s < bestScore then
				bestA = a
				bestB = b
				bestScore = s
			end
		end
	end
	if bestA == nil or bestB == nil then
		return nil, nil, nil
	end
	return bestA, bestB, bestScore
end

function Hash.range<A>(first: number, last: number, acc: A, fn: (A, number) -> A): A
	for i = first, last do
		acc = fn(acc, i)
	end
	return acc
end

function Hash.sweepArray<T>(items: { T }, faceName: string, target: TableMap, fn: (T) -> { any }?): TableMap
	local mergeFn = Hash.merge(faceName)
	return Hash.iterArray(items, target, function(acc, item)
		local pair = fn(item)
		if pair ~= nil then
			Hash.put(mergeFn, pair[1], pair[2], acc)
		end
		return acc
	end)
end

function Hash.fuse(left: TableMap, right: TableMap, faceName: string): TableMap
	if faceName ~= "keep" and faceName ~= "count" then
		error("face is not fusible: " .. tostring(faceName))
	end

	local out = table.clone(left)
	local mergeFn = Hash.merge(faceName)
	for key, value in pairs(right) do
		Hash.put(mergeFn, key, value, out)
	end
	return out
end

return Hash
