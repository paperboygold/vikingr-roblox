# Ocean Dynamics: Proof Boundary and Engineering Descent

Date: 2026-07-10

The Roblox ocean is the low-budget readout of Sanguine's finite combinatorial
fluid. The primitive state is mass and momentum in coordinate cells; oriented
faces exchange both. Height, velocity, foam, and mesh displacement are reads of
that state, not independent animations.

## Proofs already available

The current Sanguine fluid chain supplies these engineering obligations:

- `ConservativeFlux`: an internal face subtracts from one cell and adds the same amount to its neighbor.
- `WetDryCone`: a dry cell has no outgoing mass, but incoming flux can wet it.
- `ShallowWater`: conservative state is `(h, q, b)`; velocity `u = q/h` is only a read away from `h = 0`.
- `HydrostaticBalance`: flat free surface plus zero momentum remains exactly still over changing bathymetry.
- `FiniteVolumeLimiter`: a donor cannot spend more mass than it contains.
- `NavierStokesNullCell`: stress exchange is conservative and nonnegative viscosity dissipates energy.
- `CombinatorialNavierStokes3D`: 3D coordinate cells and oriented faces conserve mass and vector momentum; divergence-free flux preserves density.

Current Studio probes pass the mass-side obligations: nonuniform lake-at-rest has
zero residual, a closed 30-step transport run has mass drift `3.5e-10`, and no
cell becomes negative.

`ShorelineMomentum.lean` now adds the next closure: conservative 2D mass and both
momentum lanes, exact positive reconstruction for every submerged bed point,
available-mass-limited parcel momentum, and characteristic projection onto the
division-free Froude-one boundary `|q|^2 = g H^3`.

## Current mismatches

`Ocean.luau` now stores water height and conservative horizontal momentum
`(H, qx, qz)`. Velocity is derived only for positive depth, and every internal
parcel exchange writes equal/opposite mass and momentum. The next momentum gap
is an explicit exterior flux ledger for weather and moving solid boundaries.

Open-ocean forcing directly relaxes boundary-cell height and velocity. An open
boundary may exchange mass and momentum, but that exchange must be represented
as an oriented boundary flux so the ocean/weather ledger can account for it.

Breaking now projects supercritical shallow momentum to the Froude-one
characteristic boundary. Foam reads the removed squared-momentum fraction rather
than hand-set slope/crest thresholds. A full aeration/turbulence closure remains
open.

The corpus also lacks closures for coupled atmosphere-ocean stress, precipitation
and evaporation exchange, thermal energy/density, moving solid boundaries, and
multiresolution face reconciliation. Those should be added to Sanguine before
their Roblox forms are treated as physical primitives.

## Construction order

1. Represent incoming swell and wind stress as exterior-face fluxes. Track mass, momentum, and energy residuals each step.
2. Replace the coarse wet-face render boundary with an adaptively subdivided marching shoreline while keeping the same conservative solver cells.
3. Add a proved moving-boundary exchange. A ship hull then displaces water and receives the exact opposite impulse; wakes emerge from the same face writes.
4. Prove the aeration/turbulence read beyond the current characteristic momentum projection.
5. Couple weather through conserved exchanges: wind stress writes momentum, rain writes ocean mass while subtracting atmospheric water, evaporation reverses that exchange, and temperature writes the energy/density lane.
6. Introduce adaptive active regions with exact boundary reconciliation: broad ocean swell remains a compressed boundary carrier, shoreline and ship neighborhoods refine to shallow-water or 3D cells, and inactive interiors store their boundary readout.

Full-domain 3D Navier-Stokes at visual resolution is unnecessary on a phone. The
proof-compatible route is an exact face law at every resolution, with detail
allocated where curvature, wet/dry transitions, weather stress, or moving bodies
make the residual nonzero. Resolution changes the number of cells, not the law.

## Performance observations

- `Ocean.applyForcing` now evaluates its 20-wave spectrum only on participating open-boundary cells. At `96x96`, this reduced the measured step from `6.61 ms` to `3.28 ms` median.
- Conservative momentum plus characteristic breaking measured `3.34 ms/step` median at `96x96`, about 2% above the mass-only optimized solver.
- A shoreline pulse that previously advanced zero cells now moved the water body from cell 39 to 52 and receded to 37. Mass drift after the 40-second trace was `8.2e-10`.
- The live mesh uses a wet-face complex: mixed wet/dry triangles are absent, so no face interpolates across land. A higher-resolution marching boundary remains the route to smooth sub-cell swash.
- `OceanRenderer.client.luau` still initializes depth through `9,216` terrain raycasts and rebuilds a `96x96` mesh. A live client probe measured the bathymetry/Ocean initialization alone at `183 ms`.
- The initial client log observed an all-zero exposure field while a later probe at the same play session found `3,462` wet, `3,334` exposed, and `593` forced cells. Bathymetry currently races client terrain availability and repairs itself through repeated `setDepth` sweeps; the next startup pass should replace that polling with a deliberate terrain/bathymetry-ready handoff.
- The renderer updates thousands of editable-mesh vertices each frame. Simulation, mesh deformation, normals/colors, and terrain-depth refresh need separate profiler scopes before choosing the next representation.
