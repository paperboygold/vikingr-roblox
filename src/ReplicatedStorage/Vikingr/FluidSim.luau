--!strict
--!native

-- FluidSim — a true n-body fluid (Position-Based Fluids, Macklin–Müller 2013) built as
-- substrate machinery: neighbours via a spatial-hash CoordMap (O(1)), density = B/U
-- accumulate (Poly6), incompressibility = the constraint-collapse (density residual
-- C_i = ρ_i/ρ0 − 1 driven to 0 by the parallel λ sweep — the Hamilton–Jacobi phase /
-- pressure projection), terrain/particle contact = penetration residual → 0. The
-- collision points are where the collapse is cheapest and best-defined (the Null cell /
-- δS=0), not where it breaks.
--
-- Structure-of-arrays, pure numbers, inline neighbour loops (no per-neighbour closures),
-- fixed neighbour lists per step. Cost ∝ active particles.

local FluidSim = {}
FluidSim.__index = FluidSim

export type FluidSim = any

local function fill(n: number, v: number): { number }
	return table.create(n, v)
end

function FluidSim.new(opts: { [string]: any }): FluidSim
	local self = setmetatable({}, FluidSim) :: any
	self.h = opts.h or 6.0
	self.h2 = self.h * self.h
	self.rho0 = opts.rho0 or 1.0
	self.iters = opts.solverIters or 4
	self.gravity = opts.gravity or -40.0
	self.epsRelax = opts.epsRelax or 0.1 -- CFM relaxation (must be ~ gradSq scale, not huge)
	self.xsph = opts.xsph or 0.02
	self.sCorrK = opts.sCorrK or 0.0008
	self.sCorrN = opts.sCorrN or 4
	self.maxCorr = opts.maxCorr or (0.15 * self.h) -- clamp per-iteration position change
	self.maxSpeed = opts.maxSpeed or 55.0 -- clamp velocity (kills collision-spike escapees)
	self.velDamp = opts.velDamp or 0.01 -- global velocity bleed (settles impact energy)
	self.n = 0
	local cap = opts.capacity or 4096
	self.capacity = cap
	self.px, self.py, self.pz = fill(cap, 0), fill(cap, 0), fill(cap, 0)
	self.qx, self.qy, self.qz = fill(cap, 0), fill(cap, 0), fill(cap, 0)
	self.vx, self.vy, self.vz = fill(cap, 0), fill(cap, 0), fill(cap, 0)
	self.lambda = fill(cap, 0)
	self.rho = fill(cap, 0)
	self.nbr = {} :: { { number } } -- per-particle neighbour index lists (rebuilt each step)

	local h = self.h
	self.kPoly6 = 315.0 / (64.0 * math.pi * h ^ 9)
	self.kSpiky = -45.0 / (math.pi * h ^ 6)
	self.selfDensity = self.kPoly6 * h ^ 6 -- W_poly6(0)
	-- artificial-pressure reference term W_poly6(sCorrDq)
	local dq = 0.2 * h
	local dd = h * h - dq * dq
	self.sCorrDenom = self.kPoly6 * dd * dd * dd

	self.cell = self.h
	self.grid = {} :: { [number]: { number } }
	return self
end

function FluidSim.spawn(self: FluidSim, x: number, y: number, z: number)
	if self.n >= self.capacity then return end
	self.n += 1
	local i = self.n
	self.px[i], self.py[i], self.pz[i] = x, y, z
	self.qx[i], self.qy[i], self.qz[i] = x, y, z
	self.vx[i], self.vy[i], self.vz[i] = 0, 0, 0
end

local BIAS = 33000
local SPAN = 66000
local function cellKey(cx: number, cy: number, cz: number): number
	return (cx + BIAS) + (cy + BIAS) * SPAN + (cz + BIAS) * SPAN * SPAN
end

-- bucket predicted positions and build per-particle neighbour lists
local function buildNeighbors(self: FluidSim)
	local n, inv = self.n, 1 / self.cell
	local qx, qy, qz, h2 = self.qx, self.qy, self.qz, self.h2
	local grid = {}
	for i = 1, n do
		local k = cellKey(math.floor(qx[i] * inv), math.floor(qy[i] * inv), math.floor(qz[i] * inv))
		local b = grid[k]
		if b == nil then b = {}; grid[k] = b end
		b[#b + 1] = i
	end
	local nbr = self.nbr
	for i = 1, n do
		local list = nbr[i]
		if list == nil then list = {}; nbr[i] = list else table.clear(list) end
		local xi, yi, zi = qx[i], qy[i], qz[i]
		local cx, cy, cz = math.floor(xi * inv), math.floor(yi * inv), math.floor(zi * inv)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local b = grid[cellKey(cx + dx, cy + dy, cz + dz)]
					if b ~= nil then
						for _, j in ipairs(b) do
							if j ~= i then
								local ex, ey, ez = xi - qx[j], yi - qy[j], zi - qz[j]
								if ex * ex + ey * ey + ez * ez < h2 then
									list[#list + 1] = j
								end
							end
						end
					end
				end
			end
		end
	end
end

-- mean density of the current configuration (for rest-density calibration)
function FluidSim.measureDensity(self: FluidSim): number
	buildNeighbors(self)
	local qx, qy, qz = self.qx, self.qy, self.qz
	local kPoly6, h2, selfD = self.kPoly6, self.h2, self.selfDensity
	local sum = 0
	for i = 1, self.n do
		local dens = selfD
		local xi, yi, zi = qx[i], qy[i], qz[i]
		for _, j in ipairs(self.nbr[i]) do
			local dx, dy, dz = xi - qx[j], yi - qy[j], zi - qz[j]
			local r2 = dx * dx + dy * dy + dz * dz
			local d = h2 - r2
			dens += kPoly6 * d * d * d
		end
		self.rho[i] = dens
		sum += dens
	end
	return sum / math.max(1, self.n)
end

function FluidSim.step(self: FluidSim, dt: number, groundAt: ((number, number) -> number)?)
	local n = self.n
	if n == 0 then return end
	local px, py, pz = self.px, self.py, self.pz
	local qx, qy, qz = self.qx, self.qy, self.qz
	local vx, vy, vz = self.vx, self.vy, self.vz
	local h, h2 = self.h, self.h2
	local kPoly6, kSpiky = self.kPoly6, self.kSpiky
	local selfD, rho0, eps = self.selfDensity, self.rho0, self.epsRelax
	local lambda, rho, nbr = self.lambda, self.rho, self.nbr
	local sCorrK, sCorrN, sCorrDenom = self.sCorrK, self.sCorrN, self.sCorrDenom
	local minR = 0.01 * h
	local maxCorr = self.maxCorr

	-- predict
	for i = 1, n do
		vy[i] += self.gravity * dt
		qx[i] = px[i] + vx[i] * dt
		qy[i] = py[i] + vy[i] * dt
		qz[i] = pz[i] + vz[i] * dt
	end
	buildNeighbors(self)

	for _ = 1, self.iters do
		-- density + λ (the constraint residual and its collapse multiplier)
		for i = 1, n do
			local xi, yi, zi = qx[i], qy[i], qz[i]
			local dens = selfD
			local gxi, gyi, gzi, gradSq = 0.0, 0.0, 0.0, 0.0
			for _, j in ipairs(nbr[i]) do
				local dx, dy, dz = xi - qx[j], yi - qy[j], zi - qz[j]
				local r2 = dx * dx + dy * dy + dz * dz
				local d = h2 - r2
				dens += kPoly6 * d * d * d
				local r = math.sqrt(r2); if r < minR then r = minR end
				local w = kSpiky * (h - r) * (h - r) / r / rho0
				local gx, gy, gz = w * dx, w * dy, w * dz
				gxi += gx; gyi += gy; gzi += gz
				gradSq += gx * gx + gy * gy + gz * gz
			end
			rho[i] = dens
			gradSq += gxi * gxi + gyi * gyi + gzi * gzi
			lambda[i] = -(dens / rho0 - 1.0) / (gradSq + eps)
		end
		-- Δp with artificial pressure (s_corr) to stop clumping
		for i = 1, n do
			local xi, yi, zi = qx[i], qy[i], qz[i]
			local li = lambda[i]
			local ax, ay, az = 0.0, 0.0, 0.0
			for _, j in ipairs(nbr[i]) do
				local dx, dy, dz = xi - qx[j], yi - qy[j], zi - qz[j]
				local r2 = dx * dx + dy * dy + dz * dz
				local dpk = h2 - r2
				local wp = kPoly6 * dpk * dpk * dpk
				local ratio = wp / sCorrDenom
				local scorr = -sCorrK * ratio ^ sCorrN
				local r = math.sqrt(r2); if r < minR then r = minR end
				local w = kSpiky * (h - r) * (h - r) / r
				local coeff = (li + lambda[j] + scorr) / rho0 * w
				ax += coeff * dx; ay += coeff * dy; az += coeff * dz
			end
			-- clamp correction magnitude (stability at collisions)
			local m2 = ax * ax + ay * ay + az * az
			if m2 > maxCorr * maxCorr then
				local s = maxCorr / math.sqrt(m2)
				ax, ay, az = ax * s, ay * s, az * s
			end
			qx[i] += ax; qy[i] += ay; qz[i] += az
			if groundAt ~= nil then
				local xi2, zi2 = qx[i], qz[i]
				local g = groundAt(xi2, zi2)
				if qy[i] < g then
					-- push out along the terrain NORMAL (not just up) so sloped basin
					-- walls provide an inward force instead of letting water climb them
					local e = 1.5
					local gx = (groundAt(xi2 + e, zi2) - groundAt(xi2 - e, zi2)) / (2 * e)
					local gz = (groundAt(xi2, zi2 + e) - groundAt(xi2, zi2 - e)) / (2 * e)
					local nl = math.sqrt(gx * gx + gz * gz + 1)
					local nyy = 1 / nl
					local t = (g - qy[i]) / (nyy > 0.25 and nyy or 0.25)
					qx[i] = xi2 + (-gx / nl) * t
					qy[i] += nyy * t
					qz[i] = zi2 + (-gz / nl) * t
				end
			end
		end
	end

	-- velocity from position change (clamped) + XSPH viscosity, commit
	local maxSpeed = self.maxSpeed
	local ms2 = maxSpeed * maxSpeed
	local keep = 1 - self.velDamp
	for i = 1, n do
		local vxi = (qx[i] - px[i]) / dt * keep
		local vyi = (qy[i] - py[i]) / dt * keep
		local vzi = (qz[i] - pz[i]) / dt * keep
		local s2 = vxi * vxi + vyi * vyi + vzi * vzi
		if s2 > ms2 then
			local s = maxSpeed / math.sqrt(s2)
			vxi, vyi, vzi = vxi * s, vyi * s, vzi * s
		end
		vx[i], vy[i], vz[i] = vxi, vyi, vzi
	end
	local xsph = self.xsph
	if xsph > 0 then
		for i = 1, n do
			local xi, yi, zi = qx[i], qy[i], qz[i]
			local ax, ay, az = 0.0, 0.0, 0.0
			for _, j in ipairs(nbr[i]) do
				local dx, dy, dz = xi - qx[j], yi - qy[j], zi - qz[j]
				local d = h2 - (dx * dx + dy * dy + dz * dz)
				local wp = kPoly6 * d * d * d
				ax += (vx[j] - vx[i]) * wp; ay += (vy[j] - vy[i]) * wp; az += (vz[j] - vz[i]) * wp
			end
			vx[i] += xsph * ax; vy[i] += xsph * ay; vz[i] += xsph * az
		end
	end
	for i = 1, n do
		px[i], py[i], pz[i] = qx[i], qy[i], qz[i]
	end
end

function FluidSim.densityStats(self: FluidSim): (number, number, number)
	local n = self.n
	if n == 0 then return 0, 0, 0 end
	local mn, mx, sum = 1e18, -1e18, 0
	for i = 1, n do
		local r = self.rho[i] / self.rho0
		mn = math.min(mn, r); mx = math.max(mx, r); sum += r
	end
	return sum / n, mn, mx
end

return FluidSim
