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
| `unfrozen_fringe_darcy` | The water supply to segregation ice (Walder & Hallet 1985, GSA Bull. 96:336): a Darcy flux across one cell at the regolith's UNFROZEN permeability under the Clapeyron pressure gradient. The real frozen fringe's permeability collapses with undercooling, which is what puts the warm edge of the frost-cracking window near -3 C; here the warm edge is the tensile threshold alone and the cold edge is the pore water freezing out of the state. | A frozen-fringe permeability law kappa(dT) in the same Darcy term, once the fringe is resolvable. |
| `periodic_slice_geometry` | A slice's lateral exterior: the real neighbouring terrain continues past the side faces, while the slice wraps them into a torus, so what leaves one side re-enters the other. | Captured side-face states fed as CONSTANT/REPLAY once a global run records all six faces, or the full-planet grid at the slice's resolution. |
| `one_way_boundary_nesting` | Two-way exchange with the exterior: a REPLAY face feeds the recorded global state in, but the global run never feels what the slice does back. | Two-way nesting — the slice's face fluxes fed back into the coarse run — or the full-planet grid at the slice's resolution. |
| `boundary_relaxation_zone` | A radiating open boundary that lets outgoing waves leave. The Davies (1976) rim instead nudges each channel toward the driving face state over the outermost rows, quadratically weighted, with every nudge booked as boundary exchange. | A characteristic (radiation) condition on the momentum-pressure system at the open faces. |
| `slice_monopole_gravity` | The gravity of the whole declared body inside a slice: Poisson over the body's actual mass distribution. The slice writes the uniform-body monopole g = -G M(<r) r_hat / r^2 from the declared radius and rock density instead, so relief, the ocean and density structure do not perturb g. | GravityPass over the full-planet grid — it fills the same `gravity` buffer the slice path writes. |
