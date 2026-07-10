# Fluid Proof Gap Report

Date: 2026-07-10

Scope: Vikingr water/ocean behavior, checked against the local Sanguine proof corpus and recent arXiv references on Navier-Stokes geometry and shallow-water wet/dry finite-volume methods.

## Local Sanguine Grounding

Sanguine's own process rule is clear: if a runtime gap is mathematical, do not patch it with dialed constants first. Find the proof in `INDEX.md` and the proof modules; if it is missing, add the theorem/proof before implementation.

Relevant existing closures:

- `ShorelineMomentum.lean` proves conservative 2D mass/momentum face exchange, exact submerged-corner wetting, limited carried momentum, and Froude-one characteristic projection.

- `proof/INDEX.md` names `Algebra/NullCell` as the place where division goes singular, and QuantumField modules as the existing fluid-like proof family.
- `MadelungCell.lean` proves the Madelung split: the real channel gives the bulk-ratio quantum potential, while the imaginary channel gives continuity as current divergence.
- `MadelungEvolution.lean` carries the time-evolution split: phase evolution and density continuity.
- `QuantumEuler.lean` proves the Euler-form acceleration law by differentiating the Quantum Hamilton-Jacobi residual.
- `CellConservation.lean` proves discrete local conservation: nearest-neighbor coupling is a flux divergence and region totals change only by boundary flux.
- `CellLattice.lean` proves a local stencil and domain of dependence for a 1+1D field.
- `CellDistribution.lean` proves halo exchange reproduces global stepping over the no-communication window.
- `NullCell.lean` proves the split-complex null cone where division is singular.

Verification run:

```text
cd /home/socol/Workspace/sanguine/proof
lake build Substrate.Algebra.QuantumField.MadelungCell \
  Substrate.Algebra.QuantumField.MadelungEvolution \
  Substrate.Algebra.QuantumField.QuantumEuler \
  Substrate.Algebra.QuantumField.CellLattice \
  Substrate.Algebra.QuantumField.CellConservation \
  Substrate.Algebra.QuantumField.CellDistribution
```

Result: build completed successfully. A targeted scan found no `sorry`, `axiom`, or `assume` in the checked modules plus `NullCell.lean`.

## arXiv References

The most relevant references are not generic fluid papers. They are the ones that expose the exact invariants the Roblox solver is currently missing.

- Gilbert and Vanneste, "A geometric look at momentum flux and stress in fluid mechanics", arXiv:1911.06613. Treats momentum flux and stress as geometric boundary-valued objects and discusses Navier-Stokes, Euler, MHD, and shallow-water models. Link: https://arxiv.org/abs/1911.06613
- Califano, Rashad, and Stramigioli, "A differential geometric description of thermodynamics in continuum mechanics with application to Fourier-Navier-Stokes fluids", arXiv:2209.13216. Useful for viscosity and entropy creation as geometric thermodynamic structure rather than a visual damping knob. Link: https://arxiv.org/abs/2209.13216
- Bollermann, Chen, Kurganov, and Noelle, "A well-balanced reconstruction for wetting/drying fronts", arXiv:1412.3580. Positivity-preserving finite-volume shallow-water scheme with special wet/dry reconstruction and outgoing-flux limiting for draining cells. Link: https://arxiv.org/abs/1412.3580
- Hajduk and Kuzmin, "Bound-preserving and entropy-stable algebraic flux correction schemes for the shallow water equations with topography", arXiv:2207.07261. Requires well-balancedness, nonnegative water heights, entropy stability, lake-at-rest preservation, and property-preserving flux limiting. Link: https://arxiv.org/abs/2207.07261
- Ersing, Goldberg, and Winters, "Entropy stable hydrostatic reconstruction schemes for shallow water systems", arXiv:2406.14119. Gives hydrostatic reconstruction with entropy stability, positivity preservation, wetting/drying, multilayer support, and high-order/subcell FV blending. Link: https://arxiv.org/abs/2406.14119
- Bello, "A VFRoe scheme for 1D shallow water flows: wetting and drying simulation", arXiv:cs/0609114. Uses celerity-speed variables and a Riemann solver preserving positivity of celerity for wetting/drying. Link: https://arxiv.org/abs/cs/0609114

## Collapse Map

### 1. Navier-Stokes from NullCell

Collapse target:

```text
conservation + stress flux + dissipative entropy production
```

Existing Sanguine already has:

- Continuity as current divergence in `MadelungCell`.
- Euler acceleration from the QHJ gradient in `QuantumEuler`.
- Boundary flux conservation in `CellConservation`.
- Division singularity on the null cone in `NullCell`.

Missing rung:

```text
FluidStress.lean / NavierStokesNullCell.lean
```

The proof should express momentum change as boundary flux of momentum plus stress. Viscosity should not be a visual damping constant. It should enter as a symmetric positive semidefinite dissipative stress whose entropy production is nonnegative. That aligns with the geometric stress papers: forces are read at the boundary, while dissipation is the irreversible part of the boundary exchange.

Implementation implication:

The Roblox water solver should not attenuate waves by arbitrary distance-to-shore clamps. It should update conserved water mass and momentum by face fluxes, then add only proof-backed dissipative terms.

### 2. Saint-Venant / Shallow Water

Collapse target:

```text
depth-integrated Euler over bathymetry
```

The runtime variables should be conservative:

```text
h  = water column height
q  = h * u
b  = bottom elevation
eta = h + b
```

The dry boundary is not a mask. It is the `h = 0` singular cone where `u = q / h` is undefined. This matches the NullCell lesson: division is where the state fails. Use `(h, q)` as primitive solver state and compute velocity only where `h > 0`.

Missing rung:

```text
ShallowWater.lean
```

The proof should derive the 1D Saint-Venant conservative form from continuity plus depth-integrated momentum:

```text
partial_t h + partial_x q = 0
partial_t q + partial_x (q*q/h + 0.5*g*h*h) = -g*h*partial_x b
```

The theorem should explicitly mark `h = 0` as the division singular seam.

Implementation implication:

The current ocean mesh should become a view over a shallow-water state grid, not an independent wave function with terrain masks applied afterward.

### 3. Wet/Dry Shoreline Positivity

Collapse target:

```text
Null cone crossing + available-mass-limited outgoing flux
```

The shoreline bug, where water stops one or two blocks off shore, is exactly what happens when shoreline logic is treated as a mask instead of a cone crossing. A dry cell can receive inflow and become wet. A wet cell can drain, but it cannot send more mass through its faces than it contains.

Missing rung:

```text
WetDryCone.lean
```

Core theorem shape:

```text
if h_i >= 0 and outgoing_flux_i * dt <= h_i * dx
then h_i_next >= 0
```

Boundary corollaries:

- If `h = 0`, outgoing flux is zero.
- Incoming flux may make `h_next > 0`.
- Velocity is not read at `h = 0`.

Implementation implication:

Replace dry-cell hard stops with a flux limiter. Shoreline pooling then falls out of conservation and positivity instead of a hand-picked radius.

### 4. Bathymetry / Free Surface / Lake At Rest

Collapse target:

```text
hydrostatic balance between pressure flux and bed-slope source
```

The correct invariant is lake-at-rest:

```text
u = 0
eta = h + b = constant
```

This state must remain exactly still under the discrete update. If it does not, the solver will invent startup waves, shoreline gaps, or seafloor-reaching troughs.

Missing rung:

```text
HydrostaticBalance.lean
```

The proof should show that a hydrostatic reconstruction makes pressure-gradient flux and bathymetry source cancel in the lake-at-rest state.

Implementation implication:

Terrain height must enter the flux reconstruction itself. It should not be applied after the wave update as a separate collision or clipping step.

### 5. Finite-Volume Flux / Riemann Solver / Entropy Limiter

Collapse target:

```text
boundary exchange only + characteristic cone speeds + entropy-stable limiting
```

`CellConservation` already says region totals change by boundary flux. The shallow-water finite-volume solver is that same law with water variables on cell faces.

Missing rung:

```text
FiniteVolumeLimiter.lean
```

Proof obligations:

- Conservation: neighboring face fluxes cancel exactly.
- Positivity: height remains nonnegative under CFL and outgoing-flux limiting.
- Well-balancedness: lake-at-rest is preserved.
- Entropy inequality: numerical dissipation does not create nonphysical energy.
- Locality: signal speed is bounded by `abs(u) + sqrt(g*h)`.

Implementation implication:

The Roblox solver should move from height displacement waves to conservative face fluxes. Waves then are not global sine motion. They are characteristic information moving cell-to-cell under CFL.

## Recommended Next Proof Stack

1. `Substrate/Algebra/Fluid/ConservativeFlux.lean`
   Define 1D cell states, face fluxes, and the telescoping region-sum theorem. This generalizes the pattern already present in `CellConservation`.

2. `Substrate/Algebra/Fluid/ShallowWater.lean`
   Define `(h, q, b, eta)` and Saint-Venant flux/source terms. Prove the dry-state division seam for `u = q/h`.

3. `Substrate/Algebra/Fluid/WetDryCone.lean`
   Prove nonnegative height preservation under available-mass-limited outgoing flux.

4. `Substrate/Algebra/Fluid/HydrostaticBalance.lean`
   Prove lake-at-rest preservation for hydrostatic reconstruction.

5. `Substrate/Algebra/Fluid/EntropyFlux.lean`
   Prove the entropy inequality for the selected dissipative flux correction.

6. `Substrate/Algebra/Fluid/NavierStokesNullCell.lean`
   Add viscous stress and entropy production after the inviscid and shallow-water pieces are pinned down.

## Roblox Engineering Consequence

Do not tune the current shore mask further as if it were the final physics. The temporary solver helped expose the failure mode, but the durable route is:

```text
terrain/bathymetry grid
-> conservative shallow-water state (h, q)
-> hydrostatic face reconstruction
-> positivity-preserving wet/dry flux limiter
-> visual ocean mesh reads eta = h + b
-> foam/ripples are secondary render products
```

That route directly targets the observed problems:

- Inland lakes and rivers use the same fluid state as the ocean.
- Shore water pools into shallow areas instead of stopping at a block offset.
- Troughs cannot reach the sea floor unless mass has physically drained.
- Shore waves appear because flux actually reaches wet/dry fronts.
- Startup performance improves because the saved terrain/bathymetry grid and fluid state can be loaded instead of regenerated on every Play.
