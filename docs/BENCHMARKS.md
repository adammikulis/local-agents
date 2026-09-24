# Analytic benchmarks

Every other gate in this tree is self-consistency: books close, rest stays at rest, bytes match. These
seven compare a solver's output with a **known answer from outside this repository** — a closed form
solved in the gate's own python from published constants and published relations. Nothing in the
substance table, the kernels or the passes is consulted for the reference.

Each gate has two arms. **Arm one** is a rig: a small grid, buffers the gate controls, and the real pass
dispatched over it, so the closed form is compared with the kernel the planet runs and not with a
re-implementation. **Arm two** boots the world the sim seeds at the rung the row arrives on and reads a
published gauge, so a row that works on a rig and is absent from the planet is caught.

Each gate also carries **its own control, run before any engine starts**: the judgement is handed the
exact closed-form answer, which it must pass, and that answer deliberately wrong, which it must fail.
A gate that cannot do both exits 2 and reports nothing. That is the mutation test, and it cannot rot.

Each prints one line `BENCH_<name>={"error":…,"bound":…,"order":…}` and exits 0 within the bounds,
1 outside them, 2 when the rig could not run.

| Benchmark | Reference | Accepts | Bound, and why it is that |
|---|---|---|---|
| `check_bench_shock_tube.sh` | Exact Riemann solution of the Euler equations, Newton on the star pressure (Sod 1978; Toro, *Riemann Solvers and Numerical Methods for Fluid Dynamics*, ch. 4) | `flux.glsl` PASS_FACE and the acoustic group: the `LA_APPROX: acoustic_face_pressure` linearised face solve, `n2_eddy`, `mom_flux` | The rarefaction head and the shock must stand where the exact characteristics put them, to within `2*sqrt(a dx t/2)`, the width a first-order upwind scheme's own modified equation (Hirt 1968) diffuses a front to. Density and pressure must stay positive. The L1 error must converge at order ≥ 0.4: a monotone first-order scheme converges at 1/2 on Riemann data (Kuznetsov 1976). The overshoot past the exact solution's range must not grow under refinement. A weak arm at a 1% pressure jump, where the linearised solve IS the exact one, separates the linearisation's cost from the grid's. |
| `check_bench_heat_slab.sh` | `T = T0 + (Ts-T0) erfc(x / 2 sqrt(alpha t))`, the half-space with a step at one end (Carslaw & Jaeger, *Conduction of Heat in Solids*, 2.5). `alpha = k/(rho c)` of the table's silicate row, basalt, as the rig publishes it: `THERMAL_CONDUCT_ROCK_W_MK`, `ROCK_DENSITY_KG_M3` and `ROCK_SPECIFIC_HEAT_J_KGK` | the `heat_conduct` and `heat_conduct_lith` rows in `flux.glsl` | L1 error ≤ `(dx/2 sqrt(alpha t))^2 / 12 * max|d4 erfc|`, the 3-point Laplacian's own truncation on this profile; order ≥ 1.7, because that Laplacian is second order and the step falls as dx² between the arms. A third arm runs the fine grid at the coarse step, where the maximum principle — with the ends held, no interior point may pass either of them — is the bound, and it holds at any step size. |
| `check_bench_hydrostatic_column.sh` | `p(z) = p0 exp(-z/H)`, `H = RT/(Mg)`: the hydrostatic equation integrated at constant temperature | `state_derive.glsl`'s equation of state, and the acoustic group holding a column at rest | `(dz/H)^2 / 24` — a cell holds the AVERAGE of an exponential and the law is read at the CENTRE. The velocity a reconstruction accurate to that can generate is `g t` times it. A column seeded flat is the control and must break both bounds, or the arm is measuring an integrator that does nothing. |
| `check_bench_darcy.sh` | `K = rho g k / mu` (Darcy 1856; Bear, *Dynamics of Fluids in Porous Media*, 1972) with `k = d^2 phi^3 / (180 (1-phi)^2)` (Kozeny 1927; Carman 1937). Water at 20 °C: rho 998.2 kg/m³, mu 1.002e-3 Pa s (Kestin, Sokolov & Wakeham 1978) | the `h2o_groundwater` row and `darcy_conductivity` in `closures.glsli` | One explicit donor-cell step in float32, 1e-4 relative: the closed form IS that step, so nothing but round-off stands between them. Six columns spanning porosity and grain size, so the `phi^3/(1-phi)^2` and `d^2` dependencies are both examined rather than one point being hit. |
| `check_bench_grey_atmosphere.sh` | Stefan–Boltzmann (Stefan 1879; Boltzmann 1884) with sigma 5.670374419e-8 (CODATA 2018) and basalt emissivity 0.95 (Salisbury & D'Aria 1992); a plate at `(F(1-A)/(2 eps sigma))^(1/4)` under 1361 W/m² (Kopp & Lean 2011); the Eddington skin temperature `T_s/2^(1/4)`, which is `T^4 = (Te^4/2)(1+3 tau/2)` at tau = 0 (Eddington 1916; Goody & Yung 1989, 2.4) | the `heat_radiate` row and the band march in `transport_radiate.glsli` | Detailed balance needs no band table: two cells at the same temperature emit with the weights they absorb with, so their exchange cancels identically (Prevost 1791) and the bound is float32, 1e-5. The plate's equilibrium is bounded by a quarter of that residual, since T goes as the fourth root of the net. The skin layer is bounded by the two-stream balance its own measured band absorptivity and emissivity imply; its departure from the grey Eddington answer is exactly what a band-averaged march costs, and is reported. |
| `check_bench_jeans_escape.sh` | `Phi = n u (1+lambda) e^-lambda / (2 sqrt(pi))`, `u = sqrt(2RT/M)` (Jeans 1925; Chamberlain & Hunten, *Theory of Planetary Atmospheres*, 1987, eq. 7.2.3) | the `escape_*` rows and `escape_speed` in `closures.glsli` | float32 through one exponential, so the bound grows with lambda. Nine escape parameters from 3.5 to 15, covering four decades of the exponential. What the cell loses must also equal what the boundary book records. |
| `check_bench_phase_change.sh` | IAPWS: the triple point 273.16 K at 611.657 Pa (definitional), the enthalpy of fusion 333.426 kJ/kg (Feistel & Wagner 2006), the saturation curve (Wagner & Pruss 2002, IAPWS-95 eq. 2.5), the normal boiling point 99.974 °C | `state_derive.glsl` and the enthalpy ladder in `enthalpy.glsli` | The melting plateau's temperature is bounded by the Clausius–Clapeyron slope of the ice/liquid boundary, −7.4e-8 K/Pa across the plateau's own pressure range. Its energy width comes from a lever-rule fit and is bounded by two of the sweep's energy steps. The saturation locus is bounded by the curve's own slope over one temperature step. **At fixed volume there is no boiling plateau**: a two-phase cell climbs the saturation curve instead, and that locus is what the third claim reads. |

## Registering them

None of the seven is registered yet. To register:

- `scripts/agent_harness.sh`: add `gpu_gate check_bench_<name>` to the `lint` list, and add each name to
  the `GPU_GATES` string — `check_gpu_gate_list.sh` holds the two to each other both ways.
- `addons/local_agents/gdextensions/localagents/src/LAProcessSet.cpp`: add each gate to its rung's
  `*_GATES` array, so `la_examined` skips it when the shared capture is below that rung. The rungs are
  shock tube ACOUSTIC, heat slab CONDUCTION, hydrostatic column HYDROSTATIC, Darcy ADVECT, grey
  atmosphere RADIATION, Jeans escape CHEMISTRY, phase change STATE.
- `docs/LAUNCH_CEILING`: each gate's rig arm is one engine launch and each world arm above the shared
  capture's rung is another, so the roster grows by fourteen.
