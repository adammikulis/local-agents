# GPU Compute for the MaterialField — plan (feature/gpu-material-field)

## Goal
Move the MaterialField cellular-automaton hot loops off the CPU onto the GPU via
`RenderingDevice` compute shaders + SSBOs. The flat `PackedFloat32Array` layout (one buffer per
material + `_temp`, `_vapor`, `_cloud`, `_fog`, `_terrain_h`, `_sampled`) is already SSBO-ready. Keep
the **CPU reference step as the correctness oracle AND the headless/no-compute fallback** — the
`--headless` smoke harness has no `RenderingDevice`, so it must keep running on CPU.

Profiling (main branch) established: the field CA is the dominant *simulation* cost (coarsening the
grid 4→8 took a 300-frame headless run 45.8s→3.4s); actors are negligible. So the win is real, and it
also lets us go back UP in grid resolution (finer water/lava) once the CA is on GPU.

## Design
- New `material/MaterialGPU.gd` (`LAMaterialGPU`, RefCounted): owns a **local** `RenderingDevice`
  (`RenderingServer.create_local_rendering_device()`), the SSBOs, the compiled compute pipelines, and
  the uniform sets. Public API:
  - `static func available() -> bool` — true only if a local `RenderingDevice` was created (false in
    `--headless`/no-compute → caller stays on CPU).
  - `setup(field) -> void` — allocate SSBOs sized to `_cell_count`, seed from the field arrays.
  - `upload(name, arr)` / `download(name) -> PackedFloat32Array` — CPU⇄GPU transfer for a named buffer.
  - `step_heat(params) -> void` — dispatch the heat kernel (params = solar, dims, the tuning consts).
- Kernels live in `material/kernels/*.glsl` (`#[compute]` GLSL, `local_size_x = 64`). One invocation
  per cell; `gl_GlobalInvocationID.x` = cell index, guard `if (idx >= cell_count) return;`.
- **State residency:** keep `_temp` (and later vapor/cloud/fog) resident on the GPU across steps.
  Injection (`add_heat`, rain, evap) and SDF-coupled work stay CPU, so each step still syncs the
  buffers CPU⇄GPU as needed. Phase 1 accepts a `_temp` round-trip; later phases move more passes onto
  the GPU so one upload/download amortizes across many kernels.
- **Integration:** `MaterialField` gets `var _use_gpu: bool` and `var _gpu = null`. In `setup`, if
  `LAMaterialGPU.available()`, build `_gpu` and set `_use_gpu = true`. In `_material_step`, when
  `_use_gpu`, run the GPU heat step instead of `_heat.step()`. Everything else (liquid, atmosphere,
  combustion, gravity, render) stays exactly as-is. `_use_gpu = false` ⇒ identical to today.

## CRITICAL correctness note — conduction must be a GATHER on GPU
The CPU `MaterialHeat.step()` conduction visits each cell's **right + up** neighbour and applies the
flux to BOTH cells (`_tdelta[idx] -= f; _tdelta[ri] += f`). That scatter has a write race on the GPU
(two invocations writing the same neighbour). Rewrite it as an equivalent **gather**: each cell
computes its OWN net flux by summing over all 4 neighbours it is sampled-adjacent to:
`delta[idx] = CONDUCT_FRACTION * 0.25 * Σ_neighbours (T[n] - T[idx])` (only sampled neighbours). This
is race-free, one-pass, and numerically identical to the symmetric scatter. Then apply conduction +
ambient relax + water cooling exactly as the CPU does.

### Exact heat math to replicate (from material/MaterialHeat.gd — read it, do not guess)
Per sampled cell, per step:
1. conduction gather (above), CONDUCT_FRACTION = 0.16.
2. `solar` passed in = `_solar_input()` (sun energy × elevation), computed CPU-side and uploaded as a
   uniform (the GPU can't read the DirectionalLight3D).
3. `shade = min(CLOUD_SHADE_MAX, (cloud[idx]+fog[idx]) * CLOUD_SHADE_GAIN)`  (needs cloud/fog buffers).
4. `day_base = AMBIENT_NIGHT + (SOLAR_WARMTH*solar) * (1 - shade)`.
5. `ambient = day_base - LAPSE_RATE * max(0, terrain_h[idx] - LAPSE_REF)`.
6. `t = t + delta;  t += (ambient - t) * AMBIENT_RELAX`.
7. if `water[idx] > WATER_THRESHOLD`: `t = move_toward(t, ambient, WATER_COOL * STEP_DT)`.
   (`move_toward(a,b,d)` = `abs(b-a) <= d ? b : a + sign(b-a)*d`.)
Consts: CONDUCT_FRACTION .16, AMBIENT_RELAX .06, AMBIENT_NIGHT 6, SOLAR_WARMTH 16, LAPSE_RATE .42,
LAPSE_REF 15, WATER_COOL 300, CLOUD_SHADE_GAIN 3, CLOUD_SHADE_MAX .75, WATER_THRESHOLD .02, STEP_DT .1.
Buffers the heat kernel needs: temp (rw), terrain_h (r), sampled (r, as uint or float), cloud (r),
fog (r), water (r). dims: cell_count, dim.

## Phase 1 (this deliverable) — infrastructure + heat kernel, CPU parity, measured
1. `MaterialGPU.gd` skeleton: create local RD, `available()`, allocate the 6 SSBOs + a params uniform
   buffer, compile `heat.glsl`, build the pipeline + uniform set.
2. `heat.glsl` implementing the gather heat step above.
3. Wire `_use_gpu`/`_gpu` into `MaterialField.setup` + `_material_step` (GPU heat when available; CPU
   `_heat.step()` otherwise). Sync: upload cloud/fog/water/terrain_h/sampled as needed, keep temp GPU
   resident, download temp after the step for the CPU passes + heat texture. (Correctness first;
   optimize sync in Phase 2.)
4. **Parity check:** temporarily run BOTH (CPU into a scratch copy, GPU into temp) for a few steps and
   assert max abs diff < 1e-2 °C over sampled cells; log it. Remove the scratch once green.
5. **Measure:** windowed FPS + a `--run-frames` heat-peak trajectory with `_use_gpu` on vs off.

## Phase 2+ (follow-ups, NOT this deliverable)
- Port atmosphere transport (3 diffuse+advect passes) and the condensation step to GLSL; keep
  vapor/cloud/fog GPU-resident so heat+atmosphere share one round-trip.
- Port liquid flow (gather min-neighbour head); SDF solidify/melt stays CPU (reads GPU depth).
- Generate the heat texture on-GPU (write an R-float image from the temp SSBO) to drop that download.
- Then raise grid resolution (cell_size 6→4 or finer) now that cost is amortized.

## Guardrails / acceptance
- Explicit typing only (no `:=`) — `bash scripts/check_no_inferred_typing.sh` → OK.
- `--headless ... --run-frames=300` still prints SMOKE_SUMMARY and runs on CPU (`available()` false).
- Windowed `--shoot` GPU run: heat behaviour matches CPU (meteor crater glows + cools the same), no
  errors; report the FPS delta.
- Fail-fast intent (CLAUDE.md): GPU is the target path but the CPU step is the sanctioned headless
  fallback here, so `_use_gpu=false` on no-RD is correct (NOT a typed GPU_REQUIRED error) — real play
  gets GPU, headless gets CPU parity.
- Commit incrementally in this worktree; keep hot-path files as call-site shims.
