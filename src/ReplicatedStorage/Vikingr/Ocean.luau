--!strict
--!native

-- Ocean — conservative shallow-water cells over live bathymetry.
--
-- Primitive state is water column H plus horizontal momentum qx/qz. Velocity,
-- free-surface height, mesh deformation, and foam are derived reads. Internal
-- faces exchange one available-mass-limited parcel with equal/opposite mass and
-- momentum writes; the exact H=0 Null seam can receive flux and become wet.

local Ocean = {}
Ocean.__index = Ocean

export type Ocean = any

local function filled(n: number, v: number): { number }
	return table.create(n, v)
end

-- The seed-draw primitive (same formula as WorldSpec.hash01/hashRange — kept local so Ocean
-- stays standalone/testable). "Authored noise is a seam to be replaced": the spectrum below
-- is drawn ONCE from a few seed numbers (seed = prediction + residual), not sampled from a
-- continuous noise field every frame.
local function hash01(seed: number, i: number): number
	local v = math.sin((i * 12.9898 + seed * 78.233) * 43758.5453)
	return v - math.floor(v)
end
local function hashRange(seed: number, i: number, lo: number, hi: number): number
	return lo + hash01(seed, i) * (hi - lo)
end
local function smoothstep(lo: number, hi: number, x: number): number
	local t = math.clamp((x - lo) / math.max(1e-6, hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
end

-- The dry seam is exact. Any positive reconstructed depth is wet; velocity is
-- read only on that side of the seam.
local DRY_EPS = 0

-- opts: N, spacing, seaLevel, originX, originZ, windAngle, windStrength, depthFn
function Ocean.new(opts: { [string]: any }): Ocean
	local N = opts.N or 96
	local self = setmetatable({}, Ocean) :: any
	self.N = N
	self.spacing = opts.spacing or 20
	self.seaLevel = opts.seaLevel or 12
	self.originX = opts.originX or 0
	self.originZ = opts.originZ or 0
	-- cc = (wave speed · dt / dx)². Small on purpose: this sets a realistic (slow) wave
	-- speed (~24 studs/s → ~11 s swell period). Large cc = the twitchy "instant" waves.
	self.ccMax = opts.ccMax or 0.0012
	-- Lower than before: with boundary-driven forcing, energy injected upwind has to
	-- actually CARRY across the visible patch to reach the coast — the old higher damping
	-- was tuned for the everywhere-forced regime and starved the downwind/coastal water.
	self.damping = opts.damping or 0.006
	self.t = 0
	self.forceGain = opts.forceGain or 0.095
	self.seed = opts.seed or 4242
	self.windAngle = opts.windAngle or 0.4
	self.windStrength = opts.windStrength or 1.0
	self.swellHeight = opts.swellHeight or (self.windStrength * 3.2)
	self.boundaryRelax = opts.boundaryRelax or 3.0
	self.gravity = opts.gravity or workspace.Gravity

	local sz = N * N
	self.h = filled(sz, 0)
	self.water = filled(sz, 0)
	self.qx = filled(sz, 0)
	self.qz = filled(sz, 0)
	self.u = filled(sz, 0)
	self.v = filled(sz, 0)
	self.flux = filled(sz, 0)
	self.fluxQx = filled(sz, 0)
	self.fluxQz = filled(sz, 0)
	self.outflow = filled(sz, 0)
	self.wet = table.create(sz, true)
	self.breaking = filled(sz, 0)
	self.exposure = filled(sz, 1)
	self.forceWindow = filled(sz, 1)

	self:buildSpectrum()
	if opts.depthFn ~= nil then
		self:setDepth(opts.depthFn)
	end
	return self
end

-- A BROADBAND directional spectrum (~20 components spanning big swell down to short wind
-- chop), each a genuine traveling wave on the PDE's own dispersion relation ω = c·k. One
-- field, self-interfering across scales — this is the scale-invariant read (ObserverScale:
-- x=B/U is the same structure at coarse and fine frame), not a coarse-wave-plus-bolted-on-
-- noise-chop split. With enough incommensurate wavelengths/directions/phases, the
-- superposition is aperiodic-looking (real beat/interference, no fbm/Perlin anywhere) —
-- "authored noise is a seam"; here the seam is closed by drawing every component
-- deterministically from the seed (hashRange), the seed=prediction+residual pattern.
local SPECTRUM_N = 20
local WAVELEN_MIN, WAVELEN_MAX = 14, 620 -- short wind-chop .. big ocean swell (studs)
local DIR_SPREAD = 1.1 -- radians either side of the wind heading

function Ocean.buildSpectrum(self: Ocean)
	local dtRef = 1 / 30
	local c = math.sqrt(self.ccMax) * self.spacing / dtRef -- wave speed (studs/s)
	self.spectrum = {}
	for i = 1, SPECTRUM_N do
		-- log-spaced wavelength draw so short and long scales are both well represented
		local u = hashRange(self.seed, i * 3 + 1, 0, 1)
		local wavelength = WAVELEN_MIN * (WAVELEN_MAX / WAVELEN_MIN) ^ u
		local dirOff = hashRange(self.seed, i * 3 + 2, -DIR_SPREAD, DIR_SPREAD)
		local phase = hashRange(self.seed, i * 3 + 3, 0, 2 * math.pi)
		-- energy falls off toward short wavelengths (Pierson-Moskowitz-shaped): big swells
		-- dominate, chop rides on top with less amplitude but adds the churn/texture
		local amp = (wavelength / WAVELEN_MAX) ^ 0.85
		local dir = self.windAngle + dirOff
		local k = 2 * math.pi / wavelength
		table.insert(self.spectrum, {
			kx = math.cos(dir) * k,
			kz = math.sin(dir) * k,
			omega = c * k,
			amp = amp,
			phase = phase,
		})
	end
	-- normalise so total spectrum energy is stable regardless of SPECTRUM_N
	local norm = 0
	for _, w in ipairs(self.spectrum) do
		norm += w.amp
	end
	for _, w in ipairs(self.spectrum) do
		w.amp = w.amp / norm
	end
end

function Ocean.setWind(self: Ocean, angle: number, strength: number)
	self.windAngle = angle
	self.windStrength = strength
	self:buildSpectrum()
	self:buildExposure()
end

-- Terrain depth → bathymetry. The state variable is the water column
-- H = surface - groundY, so shorelines wet/dry by conservation instead of a fixed band.
function Ocean.setDepth(self: Ocean, depthFn: (number, number) -> number)
	local N, sp = self.N, self.spacing
	if self.groundY == nil then
		self.groundY = filled(N * N, -1e4)
	end
	local water, wet = self.water, self.wet
	local qx, qz, u, v = self.qx, self.qz, self.u, self.v
	for i = 0, N - 1 do
		for j = 0, N - 1 do
			local depth = depthFn(self.originX + i * sp, self.originZ + j * sp)
			local c = i * N + j + 1
			local ground = self.seaLevel - depth
			self.groundY[c] = ground
			local surface = self.seaLevel + self.h[c]
			local H = math.max(0, surface - ground)
			local oldH = water[c]
			local oldU = if oldH > DRY_EPS then qx[c] / oldH else 0
			local oldV = if oldH > DRY_EPS then qz[c] / oldH else 0
			water[c] = H
			if H <= DRY_EPS then
				wet[c] = false
				self.h[c] = 0
				qx[c] = 0
				qz[c] = 0
				u[c] = 0
				v[c] = 0
				self.breaking[c] = 0
			else
				wet[c] = true
				qx[c] = H * oldU
				qz[c] = H * oldV
				u[c] = oldU
				v[c] = oldV
				self.h[c] = ground + H - self.seaLevel
			end
		end
	end
	self:buildExposure()
end

-- FETCH / SHELTER — the island geometry as the determinant of the wave field. Real ocean
-- swell needs open-water FETCH (an unobstructed run upwind) to build up; without this, every
-- wet cell got identical forcing regardless of what land stood between it and the open sea,
-- which is why waves read as "one disjointed animation passing straight through an island"
-- — the sheltered/lee side was independently re-forced with the exact same global plane
-- wave as the exposed side. This is a graph walk over the wet-cell grid (the adjacency/link
-- face already used by ChunkStore, here walked in a single direction rather than all 4-ways):
-- from each wet cell, step upwind cell-by-cell; hitting land within the fetch horizon caps
-- the exposure there (short fetch = suppressed forcing = a real wave shadow); running off the
-- patch edge without hitting land means open ocean continues beyond what we track = full
-- exposure. Sheltered cells still receive real wave energy — just via actual propagation
-- through the leapfrog Laplacian coupling at the coastline, not fresh independent forcing.
local FETCH_CELLS = 45 -- fetch horizon in grid cells (~45*spacing studs of open water)
local EXPOSURE_FLOOR = 0 -- land is a hard body; lee-side water is moved only by propagated wave energy

function Ocean.buildExposure(self: Ocean)
	local N, wet, exposure = self.N, self.wet, self.exposure
	local ux, uz = -math.cos(self.windAngle), -math.sin(self.windAngle) -- step upwind (cell units)
	for i = 0, N - 1 do
		for j = 0, N - 1 do
			local c = i * N + j + 1
			if not wet[c] then
				exposure[c] = 0
			else
				local traveled = FETCH_CELLS
				local fi, fj = i, j
				for s = 1, FETCH_CELLS do
					fi += ux
					fj += uz
					local ii, jj = math.floor(fi + 0.5), math.floor(fj + 0.5)
					if ii < 0 or ii >= N or jj < 0 or jj >= N then
						break -- ran off the patch upwind without finding land: assume open ocean continues
					end
					if not wet[ii * N + jj + 1] then
						traveled = s - 1 -- land hit at step s: this much open fetch before it
						break
					end
				end
				exposure[c] = math.clamp(traveled / FETCH_CELLS, EXPOSURE_FLOOR, 1)
			end
		end
	end
	self:buildForceWindow()
end

-- BOUNDARY-DRIVEN FORCING — real ocean refraction (crests bending/splitting toward shore as
-- shallower water slows them) is an EMERGENT property of the wave PDE once cc(x,z) varies
-- with real bathymetry (which it now does, via the seabed relief field) — but only if the
-- interior is left to actually propagate it. Forcing every wet cell every frame with the
-- SAME fixed-direction plane wave (the old behaviour) overwrites that emergent signal with a
-- fresh undistorted pattern each step, which is why waves looked like one disjointed
-- animation with no real relationship to the coastline. So: inject fresh energy only in the
-- upwind portion of the patch (representing distant open-ocean swell arriving from off-
-- screen); leave the downwind portion — usually where the player and the coast are —
-- completely unforced, so what's seen there is purely the PDE's own propagation, refraction,
-- diffraction and reflection off the real seabed and coastline.
local FORCE_BAND = 0.28 -- open-ocean boundary band from the upwind edge
local FORCE_TAIL = 0.18 -- smoothstep tail width past the band before forcing reaches 0

function Ocean.buildForceWindow(self: Ocean)
	local N = self.N
	local dwx, dwz = math.cos(self.windAngle), math.sin(self.windAngle) -- downwind direction
	local corners = { { 0, 0 }, { N - 1, 0 }, { 0, N - 1 }, { N - 1, N - 1 } }
	local alongMin, alongMax = math.huge, -math.huge
	for _, cxy in ipairs(corners) do
		local a = cxy[1] * dwx + cxy[2] * dwz
		alongMin = math.min(alongMin, a)
		alongMax = math.max(alongMax, a)
	end
	local span = math.max(1e-6, alongMax - alongMin)
	local forceWindow = self.forceWindow
	for i = 0, N - 1 do
		for j = 0, N - 1 do
			local along = i * dwx + j * dwz
			local u = (along - alongMin) / span -- 0 = most upwind edge, 1 = most downwind edge
			forceWindow[i * N + j + 1] = 1 - smoothstep(FORCE_BAND, FORCE_BAND + FORCE_TAIL, u)
		end
	end
end

-- World-locked scroll: move the patch so it follows the camera while the WAVES stay
-- fixed in world space (shift the field by whole cells, fill new edge cells, re-sample
-- depth at the new origin). Lets one surface cover everywhere the observer goes.
function Ocean.recenter(self: Ocean, targetX: number, targetZ: number, depthFn: (number, number) -> number)
	local sp, N = self.spacing, self.N
	local di = math.floor((targetX - self.originX) / sp + 0.5)
	local dj = math.floor((targetZ - self.originZ) / sp + 0.5)
	if di == 0 and dj == 0 then
		return
	end
	local h, breaking = self.h, self.breaking
	local water, qx, qz, u, v = self.water, self.qx, self.qz, self.u, self.v
	local nh = table.create(N * N, 0)
	local nb = table.create(N * N, 0)
	local nw = table.create(N * N, 0)
	local nqx, nqz = table.create(N * N, 0), table.create(N * N, 0)
	local nu, nv = table.create(N * N, 0), table.create(N * N, 0)
	for i = 0, N - 1 do
		local oi = i + di
		for j = 0, N - 1 do
			local oj = j + dj
			if oi >= 0 and oi < N and oj >= 0 and oj < N then
				local nidx, oidx = i * N + j + 1, oi * N + oj + 1
				nh[nidx] = h[oidx]
				nb[nidx] = breaking[oidx]
				nw[nidx] = water[oidx]
				nqx[nidx] = qx[oidx]
				nqz[nidx] = qz[oidx]
				nu[nidx] = u[oidx]
				nv[nidx] = v[oidx]
			end
		end
	end
	self.h = nh
	self.breaking = nb
	self.water, self.qx, self.qz = nw, nqx, nqz
	self.u, self.v = nu, nv
	self.originX += di * sp
	self.originZ += dj * sp
	self:setDepth(depthFn) -- re-sample shoaling/land mask at the new origin
end

function Ocean.step(self: Ocean, dt: number)
	local N = self.N
	local sp = self.spacing
	local h = self.h
	local water, wet, groundY = self.water, self.wet, self.groundY
	if groundY == nil then
		return
	end
	local qx, qz, u, v = self.qx, self.qz, self.u, self.v
	local flux, fluxQx, fluxQz, outflow = self.flux, self.fluxQx, self.fluxQz, self.outflow
	local drag = math.exp(-self.damping * dt)
	local accel = self.gravity * dt / (2 * sp)
	self.t += dt

	-- Pressure force: velocity follows the gradient of the free surface. A dry lower cell
	-- becomes a receiver; a dry higher cell is a wall unless the surface overtops it.
	for i = 0, N - 1 do
		local rowBase = i * N
		for j = 0, N - 1 do
			local c = rowBase + j + 1
			local Hc = water[c]
			if Hc <= DRY_EPS then
				qx[c] = 0
				qz[c] = 0
				u[c] = 0
				v[c] = 0
			else
				local etaC = groundY[c] + Hc
				local e = if i < N - 1 then c + N else c
				local w = if i > 0 then c - N else c
				local n = if j < N - 1 then c + 1 else c
				local s = if j > 0 then c - 1 else c
				local etaE = if water[e] > DRY_EPS then groundY[e] + water[e] else math.max(etaC, groundY[e])
				local etaW = if water[w] > DRY_EPS then groundY[w] + water[w] else math.max(etaC, groundY[w])
				local etaN = if water[n] > DRY_EPS then groundY[n] + water[n] else math.max(etaC, groundY[n])
				local etaS = if water[s] > DRY_EPS then groundY[s] + water[s] else math.max(etaC, groundY[s])
				qx[c] = (qx[c] - Hc * accel * (etaE - etaW)) * drag
				qz[c] = (qz[c] - Hc * accel * (etaN - etaS)) * drag
				u[c] = qx[c] / Hc
				v[c] = qz[c] / Hc
			end
		end
	end

	self:applyForcing(dt)

	for c = 1, N * N do
		flux[c] = 0
		fluxQx[c] = 0
		fluxQz[c] = 0
		outflow[c] = 0
	end

	local function faceTransfer(a: number, b: number, vel: number, apply: boolean)
		if vel == 0 then
			return
		end
		local donor = if vel > 0 then a else b
		local receiver = if vel > 0 then b else a
		local donorH = water[donor]
		if donorH <= DRY_EPS then
			return
		end
		local faceDepth = groundY[donor] + donorH - math.max(groundY[a], groundY[b])
		if faceDepth <= 0 then
			return
		end
		local amount = math.abs(vel) * faceDepth * dt / sp
		if amount <= 0 then
			return
		end
		if apply then
			local available = water[donor]
			local totalOut = outflow[donor]
			if totalOut > available and totalOut > 0 then
				amount *= available / totalOut
			end
			flux[donor] -= amount
			flux[receiver] += amount
			local parcelFraction = amount / donorH
			local parcelQx = qx[donor] * parcelFraction
			local parcelQz = qz[donor] * parcelFraction
			fluxQx[donor] -= parcelQx
			fluxQx[receiver] += parcelQx
			fluxQz[donor] -= parcelQz
			fluxQz[receiver] += parcelQz
		else
			outflow[donor] += amount
		end
	end

	for pass = 1, 2 do
		local apply = pass == 2
		for i = 0, N - 1 do
			local rowBase = i * N
			for j = 0, N - 1 do
				local c = rowBase + j + 1
				if i < N - 1 then
					local e = c + N
					faceTransfer(c, e, 0.5 * (u[c] + u[e]), apply)
				end
				if j < N - 1 then
					local n = c + 1
					faceTransfer(c, n, 0.5 * (v[c] + v[n]), apply)
				end
			end
		end
	end

	for c = 1, N * N do
		local H = math.max(0, water[c] + flux[c])
		water[c] = H
		qx[c] += fluxQx[c]
		qz[c] += fluxQz[c]
		if H <= DRY_EPS then
			wet[c] = false
			h[c] = 0
			qx[c] = 0
			qz[c] = 0
			u[c] = 0
			v[c] = 0
		else
			wet[c] = true
			h[c] = groundY[c] + H - self.seaLevel
			u[c] = qx[c] / H
			v[c] = qz[c] / H
		end
	end

	self:updateBreaking(dt)
end

-- Wind spectrum body force. The "gust" is a deterministic multi-sine breathing of the
-- overall sea state (a few incommensurate slow frequencies in time — analytic, O(1), no
-- noise field): the sea calms and builds over minutes. Spatial roughness/patchiness comes
-- for free from the broadband spectrum's own interference (many incommensurate
-- wavelengths/directions/phases beat against each other), not from a bolted-on noise mask.
function Ocean.applyForcing(self: Ocean, dt: number)
	local N, wet, exposure, forceWindow = self.N, self.wet, self.exposure, self.forceWindow
	local water, groundY = self.water, self.groundY
	if groundY == nil then
		return
	end
	local qx, qz, u, v = self.qx, self.qz, self.u, self.v
	local t = self.t
	local breathe = 0.62 + 0.24 * math.sin(t * 0.021 + 1.3) + 0.14 * math.sin(t * 0.0073 - 0.4)
	local drive = self.forceGain * self.windStrength * breathe * dt
	local swell = self.swellHeight * breathe
	local relax = 1 - math.exp(-self.boundaryRelax * dt)
	local spec = self.spectrum
	local sp, ox, oz = self.spacing, self.originX, self.originZ
	local windX, windZ = math.cos(self.windAngle), math.sin(self.windAngle)
	for i = 0, N - 1 do
		local wx = ox + i * sp
		local rowBase = i * N
		for j = 0, N - 1 do
			local c = rowBase + j + 1
			local boundary = exposure[c] * forceWindow[c]
			if wet[c] and boundary > 0 then
				local wz = oz + j * sp
				local f = 0
				for waveIndex = 1, #spec do
					local w = spec[waveIndex]
					f += w.amp * math.sin(w.kx * wx + w.kz * wz - w.omega * t + w.phase)
				end
				-- Open-ocean boundary condition: outside water supplies an incoming swell.
				-- The boundary changes the water column and matching shallow-water orbital
				-- velocity; interior cells receive it only by the conservative transport step.
				local targetEta = f * swell
				local eta = groundY[c] + water[c] - self.seaLevel
				local deltaEta = (targetEta - eta) * relax * boundary
				water[c] = math.max(0, water[c] + deltaEta)
				local H = water[c]
				local orbital = targetEta * math.sqrt(self.gravity / math.max(1, H))
				local match = relax * boundary
				local targetQx = H * windX * orbital
				local targetQz = H * windZ * orbital
				qx[c] += (targetQx - qx[c]) * match
				qz[c] += (targetQz - qz[c]) * match
				local impulse = f * drive * boundary
				qx[c] += H * windX * impulse
				qz[c] += H * windZ * impulse
				if H > DRY_EPS then
					u[c] = qx[c] / H
					v[c] = qz[c] / H
				else
					qx[c] = 0
					qz[c] = 0
					u[c] = 0
					v[c] = 0
				end
			end
		end
	end
end

-- Characteristic collapse at Froude one. Supercritical horizontal momentum is
-- projected to |q|^2 = g H^3; the removed squared-momentum fraction is the foam
-- readout. No velocity or depth division occurs at the dry Null seam.
function Ocean.updateBreaking(self: Ocean, _dt: number)
	local water, qx, qz = self.water, self.qx, self.qz
	local u, v, breaking = self.u, self.v, self.breaking
	local gravity = self.gravity
	for c = 1, self.N * self.N do
		local H = water[c]
		if H <= DRY_EPS or gravity <= 0 then
			breaking[c] = 0
		else
			local momentumSq = qx[c] * qx[c] + qz[c] * qz[c]
			local characteristicSq = gravity * H * H * H
			if momentumSq > characteristicSq then
				local scale = math.sqrt(characteristicSq / momentumSq)
				qx[c] *= scale
				qz[c] *= scale
				u[c] = qx[c] / H
				v[c] = qz[c] / H
				breaking[c] = 1 - characteristicSq / momentumSq
			else
				breaking[c] = 0
			end
		end
	end
end

-- ── sampling (buoyancy + render share this) ─────────────────────────────────
function Ocean.heightAt(self: Ocean, worldX: number, worldZ: number): number
	local fi = (worldX - self.originX) / self.spacing
	local fj = (worldZ - self.originZ) / self.spacing
	local i0, j0 = math.floor(fi), math.floor(fj)
	if i0 < 0 or i0 >= self.N - 1 or j0 < 0 or j0 >= self.N - 1 then
		return self.seaLevel - 1e6
	end
	local tx, tz = fi - i0, fj - j0
	local h, wet, N = self.h, self.wet, self.N
	local c00 = i0 * N + j0 + 1
	local c10 = (i0 + 1) * N + j0 + 1
	local c01 = i0 * N + (j0 + 1) + 1
	local c11 = (i0 + 1) * N + (j0 + 1) + 1
	local wetWeight = 0
	wetWeight += wet[c00] and (1 - tx) * (1 - tz) or 0
	wetWeight += wet[c10] and tx * (1 - tz) or 0
	wetWeight += wet[c01] and (1 - tx) * tz or 0
	wetWeight += wet[c11] and tx * tz or 0
	if wetWeight <= 0.05 then
		return self.seaLevel - 1e6
	end
	local a = wet[c00] and h[c00] or 0
	local b = wet[c10] and h[c10] or 0
	local cc = wet[c01] and h[c01] or 0
	local d = wet[c11] and h[c11] or 0
	local top = a + (b - a) * tx
	local bot = cc + (d - cc) * tx
	return self.seaLevel + top + (bot - top) * tz
end

function Ocean.breakingAt(self: Ocean, worldX: number, worldZ: number): number
	local fi = (worldX - self.originX) / self.spacing
	local fj = (worldZ - self.originZ) / self.spacing
	local i0, j0 = math.floor(fi), math.floor(fj)
	if i0 < 0 or i0 >= self.N - 1 or j0 < 0 or j0 >= self.N - 1 then
		return 0
	end
	local tx, tz = fi - i0, fj - j0
	local b, N = self.breaking, self.N
	local a = b[i0 * N + j0 + 1]
	local bb = b[(i0 + 1) * N + j0 + 1]
	local c = b[i0 * N + (j0 + 1) + 1]
	local d = b[(i0 + 1) * N + (j0 + 1) + 1]
	local top = a + (bb - a) * tx
	local bot = c + (d - c) * tx
	return top + (bot - top) * tz
end

function Ocean.normalAt(self: Ocean, worldX: number, worldZ: number): Vector3
	local e = self.spacing
	local hc = self:heightAt(worldX, worldZ)
	if hc < self.seaLevel - 1e5 then
		return Vector3.yAxis
	end
	local hL = self:heightAt(worldX - e, worldZ)
	local hR = self:heightAt(worldX + e, worldZ)
	local hD = self:heightAt(worldX, worldZ - e)
	local hU = self:heightAt(worldX, worldZ + e)
	if hL < self.seaLevel - 1e5 then hL = hc end
	if hR < self.seaLevel - 1e5 then hR = hc end
	if hD < self.seaLevel - 1e5 then hD = hc end
	if hU < self.seaLevel - 1e5 then hU = hc end
	return Vector3.new(hL - hR, 2 * e, hD - hU).Unit
end

function Ocean.peak(self: Ocean): number
	local m = 0
	for _, v in ipairs(self.h) do
		local a = v < 0 and -v or v
		if a > m then m = a end
	end
	return m
end

return Ocean
