class_name LAMaterialWind3D
extends RefCounted

## LAMaterialWind3D — the EMERGENT 3D wind of the dense MaterialField3D (successor to the single global
## scalar `MaterialAtmosphere3D._wind`). Instead of one Vector2 applied identically to every cell, this
## builds a real PER-CELL air-pressure + 3D velocity field that everything downwind reads: funneling
## through valleys, fronts colliding, and highs/lows over hot/cold ground all FALL OUT of local rules
## (pressure gradients + terrain deflection), never scripted per case (see EMERGENCE.md).
##
## Mirrors the shape of LAMaterialHeat3D / LAMaterialAtmosphere3D: it holds NO grid state of its own
## (beyond the cached domain-average + prevailing input) and reaches into the owning LAMaterialField3D
## (`_f`) for the shared per-cell arrays — `_pressure`, `_vel_x`, `_vel_y`, `_vel_z`, plus `_temp`,
## `_solid`, `_dim_*`, geometry, and `sea_level`. `setup(field)` stores `_f`; `step()` advances the
## field. The math here is the CPU-oracle REFERENCE mirrored EXACTLY by the kernels3d/ GPU kernels.
##
## PHYSICS (each rule LOCAL + simple, stable over the field's fast explicit STEP_DT):
##   1) PRESSURE from state: warm air is buoyant/low-pressure, cold air dense/high-pressure —
##      p = P0 - K_T*(T - T_REF). Solid cells are walls (no flow). (The hydrostatic altitude term is
##      subsumed by driving VERTICAL motion from buoyancy in step 4, so there is no spurious global
##      updraft from an unbalanced -dp/dy.)
##   2) WIND from the pressure gradient: v += -(grad p) * ACCEL * dt, central differences to non-solid
##      neighbours (a solid neighbour reflects: its pressure reads as this cell's own, so no flow into rock).
##   3) TERRAIN DEFLECTION: zero the velocity component pointing INTO a solid neighbour. Mass funnels
##      through the gaps => valley funneling emerges for free.
##   4) BUOYANCY (vertical): a hot cell under a cooler cell accelerates UP (thermals/plumes) — this is the
##      real vertical wind that SUBSUMES the atmosphere's old fixed VAPOR_RISE fraction.
##   5) PREVAILING FORCING: a gentle body force relaxes every cell toward the large-scale prevailing wind
##      (stronger at the domain edges = inflow), so there is a base flow the terrain can bend. Fed by
##      MaterialField3D.set_wind() (the old --wind= / WeatherSystem input now forces this base flow).
##   6) DRAG: v *= (1 - DAMP) each step so it settles instead of blowing up; velocity is magnitude-clamped.
## (Explicit types only — no ':=' inferred typing.)

# --- Pressure model (own copies; MUST match wind_pressure3d.glsl) ---
const P0: float = 100.0                   # reference air pressure (arbitrary units; only gradients matter)
const K_T: float = 0.6                    # pressure drop per °C above the reference (warm air => low pressure)
const T_REF: float = 15.0                 # reference temperature the pressure curve is anchored at (= INITIAL_TEMP)

# --- Wind dynamics (own copies; MUST match wind_step3d.glsl) ---
const ACCEL: float = 0.5                  # pressure-gradient -> velocity acceleration gain (× dt)
const DAMP: float = 0.08                  # linear drag fraction removed from velocity each step
const MAX_WIND: float = 24.0              # velocity magnitude clamp (stability)
const BUOY_ACCEL: float = 0.5             # upward accel per °C of (this cell − cell above) temperature inversion
const BUOY_ACCEL_MAX: float = 6.0         # cap the buoyant accel before the dt scale (stability)
const CORIOLIS: float = 0.6               # sideways deflection of horizontal wind → pressure lows SPIN (vortices emerge)
const EDGE_FORCE: float = 0.30            # boundary cells relax this fraction toward the prevailing wind (inflow)
const BODY_FORCE: float = 0.02            # interior cells relax this gentle fraction toward the prevailing wind

var _f = null                                            # back-reference to the owning LAMaterialField3D
var _prevailing: Vector2 = Vector2.ZERO                  # large-scale base wind (world XZ) forced at edges/body
var _avg_wind: Vector2 = Vector2.ZERO                    # cached domain-average horizontal wind (wind()/HUD/ocean)
var _enable_buoyancy: bool = true                        # stage-3 vertical wind (subsumes VAPOR_RISE)


func setup(field) -> void:
	_f = field


## Set the large-scale prevailing wind (world XZ; x=+X, y=+Z) forced at the domain edges + as a gentle
## body flow. This is the ONE external input (old --wind= / WeatherSystem drift) — the local circulation
## then emerges on top of it from pressure + terrain.
func set_prevailing(w: Vector2) -> void:
	if is_nan(w.x) or is_nan(w.y) or is_inf(w.x) or is_inf(w.y):
		return
	_prevailing = w


func prevailing() -> Vector2:
	return _prevailing


## Cached domain-average horizontal wind — the ONE scalar legacy consumers (ocean swell, HUD) read.
func avg_wind() -> Vector2:
	return _avg_wind


## Recompute the cached domain-average horizontal wind from the field's CURRENT velocity arrays. Used on
## the GPU path, where step() runs on-device and this module no longer scans the grid: after the GPU vel
## readback the field calls this ONE cheap flat reduction (over non-solid cells, matching step()'s mean)
## to refresh avg_wind() for the ocean/HUD. On the CPU path step() sets _avg_wind directly instead.
func recompute_avg_from_field() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	var vx: PackedFloat32Array = _f._vel_x
	var vz: PackedFloat32Array = _f._vel_z
	var solid: PackedByteArray = _f._solid
	var sum_x: float = 0.0
	var sum_z: float = 0.0
	var void_cells: int = 0
	for i in range(_f._cell_count):
		if solid[i] == 0:
			sum_x += vx[i]
			sum_z += vz[i]
			void_cells += 1
	var denom: float = maxf(1.0, float(void_cells))
	_avg_wind = Vector2(sum_x / denom, sum_z / denom)


## One wind step: (A) recompute pressure from the current temperature, then (B) accelerate the velocity
## field down the pressure gradient, add buoyant lift, force it toward the prevailing base flow, deflect
## it off rock faces, and damp it. Pressure is fully computed before any gradient is read (neighbour
## pressures), so the two passes are order-independent; the velocity update is per-cell (no momentum
## advection yet) so it updates in place safely.
func step() -> void:
	if _f._cell_count <= 0:
		return
	var dx: int = _f._dim_x
	var dy: int = _f._dim_y
	var dz: int = _f._dim_z
	var layer: int = dx * dz
	var solid: PackedByteArray = _f._solid
	var temp: PackedFloat32Array = _f._temp
	var pressure: PackedFloat32Array = _f._pressure
	var vx: PackedFloat32Array = _f._vel_x
	var vy: PackedFloat32Array = _f._vel_y
	var vz: PackedFloat32Array = _f._vel_z
	var dt: float = _f.STEP_DT

	# --- PASS A: pressure from temperature (warm => low). Solid cells carry P0 (a neutral wall value so a
	# reflective neighbour read sees no cross-wall gradient). ---
	for i in range(_f._cell_count):
		if solid[i] != 0:
			pressure[i] = P0
		else:
			pressure[i] = P0 - K_T * (temp[i] - T_REF)

	# --- PASS B: velocity update (gradient accel + buoyancy + prevailing forcing + deflection + drag). ---
	var pvx: float = _prevailing.x
	var pvz: float = _prevailing.y
	var buoy_on: bool = _enable_buoyancy
	var sum_x: float = 0.0
	var sum_z: float = 0.0
	var void_cells: int = 0
	for iy in range(dy):
		for iz in range(dz):
			for ix in range(dx):
				var i: int = (iy * dz + iz) * dx + ix
				if solid[i] != 0:
					vx[i] = 0.0
					vy[i] = 0.0
					vz[i] = 0.0
					continue
				var p0c: float = pressure[i]

				# Central-difference pressure gradient; a solid/out-of-bounds neighbour reflects (reads p0c).
				var px_hi: float = pressure[i + 1] if ix < dx - 1 and solid[i + 1] == 0 else p0c
				var px_lo: float = pressure[i - 1] if ix > 0 and solid[i - 1] == 0 else p0c
				var pz_hi: float = pressure[i + dx] if iz < dz - 1 and solid[i + dx] == 0 else p0c
				var pz_lo: float = pressure[i - dx] if iz > 0 and solid[i - dx] == 0 else p0c
				var gx: float = 0.5 * (px_hi - px_lo)
				var gz: float = 0.5 * (pz_hi - pz_lo)

				var nvx: float = vx[i] - gx * ACCEL * dt
				var nvz: float = vz[i] - gz * ACCEL * dt
				var nvy: float = vy[i]

				# BUOYANCY (vertical wind): a hot cell under a cooler open cell rises. Subsumes VAPOR_RISE.
				if buoy_on and iy < dy - 1:
					var iu: int = i + layer
					if solid[iu] == 0:
						var inv: float = temp[i] - temp[iu]
						if inv > 0.0:
							nvy += minf(inv * BUOY_ACCEL, BUOY_ACCEL_MAX) * dt

				# CORIOLIS-like deflection: air rushing INTO a pressure low is curled sideways, so instead of
				# collapsing straight to the centre it spins AROUND it — a rotating low (vortex) EMERGES. A
				# deeper low (stronger inflow) spins tighter, so a sharp local low (a convective updraft, a
				# seeded warm-ocean low) becomes a TORNADO / mesocyclone / hurricane with no scripted rotation.
				# Semi-implicit rotation by the pre-rotation components (stable). Must match wind_step3d.glsl.
				var rvx: float = nvx - CORIOLIS * nvz * dt
				var rvz: float = nvz + CORIOLIS * nvx * dt
				nvx = rvx
				nvz = rvz

				# PREVAILING base flow: stronger at the domain boundary (inflow), gentle in the interior.
				var on_edge: bool = ix == 0 or ix == dx - 1 or iz == 0 or iz == dz - 1
				var force: float = EDGE_FORCE if on_edge else BODY_FORCE
				nvx += (pvx - nvx) * force
				nvz += (pvz - nvz) * force

				# DRAG.
				nvx *= (1.0 - DAMP)
				nvy *= (1.0 - DAMP)
				nvz *= (1.0 - DAMP)

				# TERRAIN DEFLECTION: cannot blow INTO a solid neighbour — zero that component.
				if nvx > 0.0 and (ix >= dx - 1 or solid[i + 1] != 0):
					nvx = 0.0
				elif nvx < 0.0 and (ix <= 0 or solid[i - 1] != 0):
					nvx = 0.0
				if nvz > 0.0 and (iz >= dz - 1 or solid[i + dx] != 0):
					nvz = 0.0
				elif nvz < 0.0 and (iz <= 0 or solid[i - dx] != 0):
					nvz = 0.0
				if nvy > 0.0 and (iy >= dy - 1 or solid[i + layer] != 0):
					nvy = 0.0
				elif nvy < 0.0 and (iy <= 0 or solid[i - layer] != 0):
					nvy = 0.0

				# Magnitude clamp (stability).
				var sp2: float = nvx * nvx + nvy * nvy + nvz * nvz
				if sp2 > MAX_WIND * MAX_WIND:
					var s: float = MAX_WIND / sqrt(sp2)
					nvx *= s
					nvy *= s
					nvz *= s

				vx[i] = nvx
				vy[i] = nvy
				vz[i] = nvz
				sum_x += nvx
				sum_z += nvz
				void_cells += 1

	var denom: float = maxf(1.0, float(void_cells))
	_avg_wind = Vector2(sum_x / denom, sum_z / denom)
