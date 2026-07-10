--!strict
--!native

local WorldSpec = {}

export type Config = {
	seed: number,
	width: number,
	depth: number,
	cellSize: number,
	chunkSize: number,
	seaLevel: number,
	waterDepth: number,
	maxHeight: number,
	walkSpeed: number,
	voxelResolution: number,
	voxelChunkCells: number,
	coastRampCells: number,
	riverCount: number,
	lakeCount: number,
	terrainMode: string,
	voxelChunksPerYield: number,
}

WorldSpec.Config = {
	seed = 7937,
	width = 112,
	depth = 82,
	cellSize = 48,
	chunkSize = 8,
	seaLevel = 12,
	waterDepth = 48,
	maxHeight = 190,
	walkSpeed = 16,
	voxelResolution = 4,
	voxelChunkCells = 4,
	coastRampCells = 14,
	riverCount = 8,
	lakeCount = 10,
	terrainMode = "voxels",
	voxelChunksPerYield = 4,
}

function WorldSpec.cloneConfig(overrides: { [string]: any }?): Config
	local config = table.clone(WorldSpec.Config)
	if overrides ~= nil then
		for key, value in pairs(overrides) do
			config[key] = value
		end
	end
	return config :: Config
end

function WorldSpec.hash01(seed: number, x: number, z: number): number
	local v = math.sin((x * 12.9898 + z * 78.233 + seed * 0.173) * 43758.5453)
	return v - math.floor(v)
end

-- Deterministic scalar draw in [lo, hi] from a seed and an integer index.
function WorldSpec.hashRange(seed: number, index: number, lo: number, hi: number): number
	return lo + WorldSpec.hash01(seed, index, 0) * (hi - lo)
end

function WorldSpec.clamp01(x: number): number
	if x < 0 then
		return 0
	elseif x > 1 then
		return 1
	end
	return x
end

function WorldSpec.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Hermite smoothstep over [edge0, edge1]; 0 below edge0, 1 above edge1.
function WorldSpec.smoothstep(edge0: number, edge1: number, x: number): number
	if edge0 == edge1 then
		return x < edge0 and 0 or 1
	end
	local t = WorldSpec.clamp01((x - edge0) / (edge1 - edge0))
	return t * t * (3 - 2 * t)
end

-- Quintic smootherstep (zero 1st & 2nd derivative at the edges) — gentler ramps.
function WorldSpec.smootherstep(edge0: number, edge1: number, x: number): number
	if edge0 == edge1 then
		return x < edge0 and 0 or 1
	end
	local t = WorldSpec.clamp01((x - edge0) / (edge1 - edge0))
	return t * t * t * (t * (t * 6 - 15) + 10)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Tuning — seed-independent knobs for the field-first pipeline.
-- Config holds the runtime scalar contract (size, seaLevel, ...); Tuning holds
-- the shape constants each field module reads. Grouped by stage.
-- ═══════════════════════════════════════════════════════════════════════════
WorldSpec.Tuning = {
	continent = {
		-- Sea corridor runs along z (width 112 > depth 82 → widest cross-sea reach).
		channelX0Range = { -8, 8 }, -- centerline base offset (cells)
		channelAmpRange = { 6, 10 }, -- meander amplitude (cells)
		channelOmega = 0.05, -- meander angular frequency in z
		seaHalfWidth = 14, -- Wsea: guaranteed-sea half-width (cells) → 2*14*48 = 1344 studs
		shelfFalloff = 8, -- shelfW: falloff band beyond the guaranteed sea

		-- Two primary landmasses (fractions of halfW for x, cells for z).
		centerXFrac = { 0.45, 0.6 },
		centerZRange = { -14, 14 },
		radiusX = 26,
		radiusZ = 34,
		primaryWeight = 1.0,

		-- Secondary blobs per side (cannot bridge the channel — enforced in code).
		secondaryPerSide = 2,
		secondaryRadius = 10,
		secondaryWeight = 0.55,

		-- Domain warp (organic coasts). warpAmp is clamped in code so it can never
		-- push a coast into the corridor.
		warpFreq = 0.03,
		warpAmpMax = 6,

		seaBias = 0.35, -- pushes the neutral level toward sea
		channelDepth = 4.0, -- must dominate max land potential + detail + seaBias
		coastRough = 0.12, -- small crenulation amplitude
		coastRoughFreq = 0.22,

		-- continentality (C) → base elevation
		landHeight = 26, -- studs of land rise at full continentality
		pLand = 1.6, -- >1 → shallow coastal plain near shore, steeper inland
		cLand = 1.0, -- C at which land reaches full landHeight
		shelfDrop = 14, -- studs the shelf sinks before deep ocean
		cShelf = 0.6, -- |C| at which shelf reaches deep ocean
	},

	relief = {
		peakRelief = 150, -- max studs of mountain relief added on top of base
		cPlain = 0.28, -- continentality threshold before ANY mountains (coastal plain)
		cRamp = 0.55, -- ramp width for the coastal-plain envelope
		orogenyMix = 0.62, -- blend interior swell vs mountain belts
		beltAxisAngleRange = { -0.6, 0.6 }, -- tectonic axis orientation (radians) from seed
		beltFreq = 0.045,
		beltThreshold = 0.5, -- ridged value above which a mountain belt forms
		-- ridged multifractal residual (the ONLY multi-octave noise)
		residualOctaves = 5,
		residualF0 = 0.03,
		residualLacunarity = 2.0,
		residualGain = 0.5,

		-- seabed: the SAME residual field, recentred to signed [-1,1] so it gives both
		-- ridges/seamounts (+) and canyons/trenches (-), envelope-gated to start where the
		-- shelf finishes sinking (real explorable bathymetry, not a flat slab)
		peakReliefUnderwater = 20, -- max studs of seabed relief either side of the base
		underwaterRampT0 = 0.6, -- |C| (matches cShelf) where seabed relief starts
		underwaterRampT1 = 1.6, -- |C| where seabed relief reaches full amplitude
		seabedClearance = 6, -- min studs kept below sea level (never breaches the surface)
	},

	climate = {
		baseTemp = 12, -- °C-ish at sea level, mid-latitude
		latGrad = -10, -- temperature change from mid to far edge (colder north)
		lapse = 0.02, -- °C per stud of elevation above sea
		snowTemp = -1, -- below this → snow material
		windAngleRange = { 2.2, 3.9 }, -- prevailing wind direction (radians) from seed
		humidity0 = 1.0, -- humidity entering at the upwind ocean edge
		baseRate = 0.02, -- background precipitation fraction per cell
		oroRate = 0.9, -- orographic precipitation per unit upslope
		replenish = 0.5, -- humidity regained per cell over ocean
	},

	hydrology = {
		epsilon = 1e-3, -- priority-flood fill increment (guarantees descending paths)
		lakeTolerance = 0.15, -- filled-above-raw beyond this → lake cell
		riverLandFraction = 0.06, -- ~fraction of land channelized into rivers (adaptive threshold)
		riverAccumFloor = 0.05, -- absolute floor on the river threshold (flow units)
	},

	erosion = {
		-- Light touch: enough to smooth hillslopes, few enough passes that basins
		-- (lakes) survive rather than being diffused flat.
		passes = 4,
		kStream = 0.0005, -- stream-power incision coefficient
		mExp = 0.5, -- area exponent
		nExp = 1.0, -- slope exponent
		kDiff = 0.06, -- thermal / hillslope diffusion (Laplacian)
		kDep = 0.00008, -- deposition coefficient
		depSlope = 0.6, -- slope below which deposition kicks in
		minElevOffset = -4, -- floor below seaLevel the surface may erode to
	},

	biome = {
		-- slope is measured in studs of elevation change per 1 cell of horizontal step
		cliffSlope = 7, -- above this on a coast → cliff
		ridgeSlope = 5,
		hillSlope = 2.5,
		flatSlope = 1.5, -- below this counts as flat (marsh/plain)
		ridgeElev = 60, -- studs above sea for ridge candidacy
		hillElev = 22,
		marshBand = 8, -- studs above sea within which marshes can sit
		marshRain = 0.015, -- rainfall above this (in flat, near-sea cells) → marsh
		snowElev = 90, -- fallback snow line if temperature unavailable
	},

	-- Water rendering: steady-state hydraulic geometry (the O(1) closed-form solution
	-- of the shallow-water equations) → channel width/depth from discharge, rasterized
	-- as a continuous footprint so rivers are smooth, not per-cell diagonal blocks.
	water = {
		widthCoeff = 7.0, -- W (studs) = widthCoeff * discharge^widthExp
		widthExp = 0.5,
		-- minWidth >= ~1.25 cells so even headwater streams span the cell diagonal and
		-- stay continuous across D8 diagonal steps (a game-legibility floor, not realism).
		minWidth = 60,
		maxWidth = 240,
		depthCoeff = 1.1, -- D (studs) = depthCoeff * discharge^depthExp
		depthExp = 0.35,
		minDepth = 2,
		maxDepth = 16,
		-- >= 1 cell so a finite signed halo surrounds every channel → clean bilerp, no
		-- sentinel-corrupted edges.
		bankMargin = 48,
		surfaceDrop = 0.4, -- water surface this far below local ground
	},

	-- Shallow-water flux relaxation (the pipe model — erosion's sibling operator).
	-- Channels are first incised into the terrain (monotone to sea, widened by
	-- discharge), then water is relaxed to a steady surface: flat lakes, connected
	-- rivers that open to the ocean, sub-cell shorelines, a velocity field for current.
	watersim = {
		-- terrain incision
		carveDrop = 0.6, -- min bed drop per cell downstream (guarantees descent)
		carveDepthCoeff = 1.4, -- channel depth (studs) = coeff * discharge^depthExp
		carveDepthExp = 0.32,
		carveMinDepth = 3,
		carveMaxDepth = 20,
		carveMinRadius = 52, -- >= 1 cell so diagonal corners are carved (no bars)
		mouthDrop = 3, -- bed at a river mouth sits this far below sea level
		-- flux relaxation
		iterations = 60,
		dt = 0.6,
		gravity = 9.8,
		pipeArea = 18,
		fluxDamp = 0.92,
		minRenderDepth = 0.5, -- studs; thinner sheets are not drawn
		flowThreshold = 6, -- flux magnitude above which water is drawn as "river" (flowing)
	},

	sites = {
		portsPerLandmass = 3,
		marshPasses = 3,
		forestPasses = 2,
		coastRoughPasses = 2,
		minLandmassCells = 150,
	},
}

function WorldSpec.worldPoint(config: Config, x: number, z: number, y: number?): Vector3
	return Vector3.new((x + 0.5) * config.cellSize, y or 0, (z + 0.5) * config.cellSize)
end

function WorldSpec.walkSeconds(config: Config, cells: number): number
	return (cells * config.cellSize) / config.walkSpeed
end

return WorldSpec
