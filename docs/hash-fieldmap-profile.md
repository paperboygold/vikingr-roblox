# Hash / FieldMap Profile

Date: 2026-07-10

Command:

```sh
./docs/run-hash-fieldmap-bench.sh
```

Baseline key-shape result before migrating FieldMap off string cell keys:

```text
string-dict field        0.204317 checksum=243717.657
coord-table field        0.642151 checksum=243878.157
number-dict packed       0.057285 checksum=243717.657
number-dict dense        0.026716 checksum=243717.657
coord-table dense        0.338916 checksum=243717.657
```

After the Hash strict-type cleanup and FieldMap numeric-key migration:

```text
string-dict field        0.188051 checksum=243717.657
coord-table field        0.646549 checksum=243878.157
number-dict packed       0.057182 checksum=243717.657
number-dict dense        0.027020 checksum=243717.657
coord-table dense        0.351075 checksum=243717.657
```

After replacing the 16-bit packed cell key with reversible signed pairing
(`Hash.cellCoord(-7, 12) == 589`, no fixed world-size bound), local microbench
runs were noisy but the best/typical numeric packed lane moved into the same
order as before while producing small integer keys:

```text
string-dict field        0.174299 checksum=243717.657
coord-table field        0.347277 checksum=243717.657
number-dict packed       0.049900 checksum=243717.657
number-dict dense        0.029986 checksum=243717.657
coord-table dense        0.350787 checksum=243717.657
```

Fresh Studio Server runtime, current map size, no terrain write:

```text
before signed pairing: buildMs=23.40 fieldMs=337.76 totalMs=361.16
after signed pairing:  buildMs=11.39 fieldMs=252.53 totalMs=263.92
```

`Hash.GridMap` was implemented and validated, but the metatable-backed dense
face is not suitable for FieldMap hot reads/writes yet:

```text
grid-map field           0.550829 checksum=243717.657
number-dict dense        0.036172 checksum=243717.657
```

The shipped FieldMap path instead uses active bounded dense integer keys with
plain Luau numeric tables. Fresh Studio Server runtime, current map size, no
terrain write:

```text
dense active key cold:   buildMs=14.87 fieldMs=270.68 totalMs=285.55
dense active key warm 1: buildMs=12.13 fieldMs=159.50 totalMs=171.63
dense active key warm 2: buildMs=9.58  fieldMs=190.13 totalMs=199.71
```

Interpretation:

- The current FieldMap migration targets the `number-dict packed` lane: about 3.3x faster than string keys on this CLI workload.
- The custom Luau `Hash.CoordMap` is semantically useful as a hashtrinity mirror, but it is not the fastest Luau hot path yet.
- Signed pairing preserves stateless coordinate keys while mapping near-origin cells to small integers, which improved the fresh Studio generation bench by about 27% total time.
- The faster shipped FieldMap path is active bounded dense integer keys over plain Luau tables. This is less general than signed pairing, but it matches the current single-build terrain pipeline and is substantially faster once warm.
- `Hash.GridMap` remains as a semantic primitive, but it should not be used in the FieldMap hot path until it can avoid metamethod tax.

Stage profiling added to `TerrainField.build` on 2026-07-10 showed `WaterSim`
as the next single hot primitive:

```text
stage baseline: buildMs=9.82 fieldMs=170.14 totalMs=179.96
macro=6.02 climate=5.56 hydrologySolve=13.54 erosion=5.31 hydrologyRefine=17.04 waterSim=107.40 regime=9.17 sites=5.71 toState=0.36
```

After collapsing `WaterSim.solve` from per-iteration coordinate parsing and
neighbor key construction into a precomputed neighbor basis:

```text
water basis: buildMs=9.76 fieldMs=111.15 totalMs=120.91
waterSim=46.20 hydrologySolve=15.03 hydrologyRefine=15.68 regime=9.39 sites=4.21
```

After collapsing the water sweep further into dense ordinal arrays (`cell index
-> east/west/north/south index`, with sea/off-map as sink index 0):

```text
ordinal sample: buildMs=14.07 fieldMs=123.19 totalMs=137.26
waterSim=25.30 hydrologySolve=25.33 hydrologyRefine=22.23 regime=9.41 sites=6.40

ordinal repeats, no terrain write:
1: buildMs=14.02 fieldMs=101.66 totalMs=115.68 waterSim=21.55 hydrologySolve=13.42 hydrologyRefine=27.54 regime=11.67
2: buildMs=21.82 fieldMs=159.87 totalMs=181.69 waterSim=46.33 hydrologySolve=15.75 hydrologyRefine=15.65 regime=42.41
3: buildMs=14.35 fieldMs=79.63  totalMs=93.98  waterSim=14.25 hydrologySolve=20.18 hydrologyRefine=15.46 regime=8.48
```

After replacing hydrology heap entries `{prio, key}` with parallel `prio[]` and
`val[]` arrays:

```text
heap-array repeats, no terrain write:
1: buildMs=9.92  fieldMs=103.78 totalMs=113.70 hydrologySolve=12.48 hydrologyRefine=14.94 waterSim=22.32 regime=26.06
2: buildMs=30.88 fieldMs=83.21  totalMs=114.09 hydrologySolve=12.66 hydrologyRefine=15.21 waterSim=21.50 regime=10.79
3: buildMs=13.78 fieldMs=147.86 totalMs=161.64 hydrologySolve=10.87 hydrologyRefine=23.26 waterSim=47.58 regime=25.18
```

After collapsing `RegimeField` local fact reads so elevation, slope, rainfall,
coast, and cardinal neighbor keys are computed once per land cell:

```text
regime-fact repeats, no terrain write:
1: buildMs=20.84 fieldMs=127.82 totalMs=148.66 regime=7.14  hydrologySolve=47.58 hydrologyRefine=12.49 waterSim=15.82
2: buildMs=18.57 fieldMs=93.67  totalMs=112.24 regime=11.13 hydrologySolve=11.46 hydrologyRefine=16.45 waterSim=26.11
3: buildMs=15.87 fieldMs=78.57  totalMs=94.44  regime=6.72  hydrologySolve=12.53 hydrologyRefine=13.66 waterSim=23.73
```

After replacing Hydrology's repeated coordinate parse/bounds/key work with the
shared dense eight-lane oriented topology (`0` = exterior Null seam):

```text
five-run baseline median:
fieldMs=86.67 totalMs=106.31 hydrologySolve=12.31 hydrologyRefine=17.34

five-run topology median:
fieldMs=72.97 totalMs=90.30 hydrologySolve=8.72 hydrologyRefine=8.75

change:
field -15.8% total -15.1% hydrologySolve -29.2% hydrologyRefine -49.5%
```

Topology validation in Studio covered all `9,184` cells / `73,472` lanes:
zero invalid addresses and zero asymmetric internal links. Generation retained
`4,242` land cells, `252` river cells, `15` lake cells in four basins, and an
acyclic receiver graph. The topology also removes the former coast-edge alias:
out-of-domain neighbors are now address `0`, never a wrapped dense key.

The same measurement pass found a dead read in `Ocean.applyForcing`: the full
20-component spectrum was evaluated before checking whether a cell belonged to
the open-ocean forcing boundary. At the production `96x96` resolution only
`4,089 / 9,216` cells participate. Moving the boundary read before the spectrum
fold reduced a 20-step Studio server benchmark from `6.61 ms/step` to a
five-run median of `3.28 ms/step` without changing any participating-cell math.

Notes:

- Studio timings still have visible GC/scheduler noise, so use medians or repeated samples rather than one-off timings.
- The main water improvement is semantic as well as faster: dense key boundary aliases are now blocked for water and regime adjacency by using explicit sea/off-map sink handling at grid edges.
- Hydrology, lake components, and coast adjacency now share the same oriented topology; future weather advection and local fluid regions should consume that basis rather than rebuilding coordinate neighbors.
- The ocean's next correctness collapse is conservative momentum (`q = h*u`) and explicit boundary flux accounting, not another visual wave clamp.
