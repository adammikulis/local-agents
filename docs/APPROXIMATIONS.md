# Declared approximations

Every cheaper-solver-of-the-same-shape lives here. The rule and its three conditions are in `CLAUDE.md`;
this is the scoreboard, and progress is rows leaving it as compute allows.

A row is only legal if the SHAPE is real — the functional form, the dependencies and the direction of every
effect — and only the resolution or the solver is cheapened. A number back-derived from the answer is a
fitted constant, not an approximation, and belongs in neither this file nor the tree.

Mark the site in code with `LA_APPROX: <key>` on the line above it. `scripts/check_approximations.sh` fails
the build when a marker has no row, when a row has no marker, or when a row names no replacement.

| key | stands in for | what swaps it in |
|---|---|---|
| `band_averaged_transmittance` | Per-band radiative transfer. The longwave march Planck-weights transmittance across all bands BEFORE carrying it cell to cell, so a long path absorbs more than it should — band averaging closes windows nature leaves open (correlated-k). | A per-band march, or a correlated-k table with sorted g-points, once six directions × bands per cell is affordable. |
| `fixed_sweep_relaxation` | The per-step gravity solve. A fixed count of red-black sweeps propagates information a few cells per solve rather than across the grid, so after a large sudden mass change the potential lags the mass. The seeding solve is converged; only the per-step one is capped. | A geometric multigrid V-cycle: same discrete operator, same fixed point, O(N) per cycle. |
| `quasi_static_solid_pressure` | The pressure of the SOLID interior. An open cell's pressure is a state function of its own matter, solved from the equation of state in `state_derive.glsl`; a solid cell's drops the dynamic term and takes the weight of the column standing over it instead, starting from the pressure of the fluid on the surface. Rock's bulk modulus makes a state-function pressure hypersensitive — one part per million of fill is ~80 kPa — so the interior cannot hold a monotone profile against ordinary transport noise. | The same `la_eos_p` the open cells already use, applied to solid cells too, once acoustic sub-stepping at the rock sound speed is affordable and the seed carries the compression exactly. The replacement is the branch beside it, not a rewrite. |
| `unfrozen_fringe_darcy` | The water supply to segregation ice (Walder & Hallet 1985, GSA Bull. 96:336): a Darcy flux across one cell at the regolith's UNFROZEN permeability under the Clapeyron pressure gradient. The real frozen fringe's permeability collapses with undercooling, which is what puts the warm edge of the frost-cracking window near -3 C; here the warm edge is the tensile threshold alone and the cold edge is the pore water freezing out of the state. | A frozen-fringe permeability law kappa(dT) in the same Darcy term, once the fringe is resolvable. |
