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
