extends RefCounted

## The one airborne-tracer transport kernel: its path, its push constant, and the settling law every tracer
## enters it with. Gases, atmospheric moisture and dust all go through it; the only per-tracer terms are the
## settling velocity and whether the tracer has a settled phase to deposit into.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"

## Symmetric eddy-mixing share per open neighbour, for the gases and for dust.
const EDDY_DIFFUSE: float = 0.02
## Still-air settling velocity per unit of fractional molar-mass excess over dry air, m/s.
const SETTLE_V_PER_CONTRAST: float = 0.05


## Fractional molar-mass excess of a gas over dry air. Negative for a gas lighter than air, which rises.
static func molar_contrast(molar_mass_kg_mol: float) -> float:
	return molar_mass_kg_mol / LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL - 1.0


## Still-air settling velocity of a gas, m/s. Signed: >0 sinks, <0 rises.
static func gas_settle_v(molar_mass_kg_mol: float) -> float:
	return SETTLE_V_PER_CONTRAST * molar_contrast(molar_mass_kg_mol)


## Still-air settling velocity of the airborne grain, m/s, from Stokes drag. The `dust` channel carries no
## per-cell grain diameter, so every grain settles as GRAIN_D_UPLAND_M.
static func dust_settle_v() -> float:
	return LAPhysical.stokes_settling_velocity(LAPhysical.GRAIN_D_UPLAND_M,
			LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S)


## Courant factor k = dt/dx: real seconds per field step over the cell size in real metres. The velocity
## field is m/s, so dividing by a model-unit cell size would pin every cell against the kernel's CFL cap.
static func courant(cell_size_model_units: float) -> float:
	var cell_m: float = cell_size_model_units * LAPhysical.METRES_PER_MODEL_UNIT
	if cell_m == 0.0:
		return 0.0
	return LAMaterialFieldSphereStep3D.real_seconds_per_step() / cell_m


## The kernel's uniform-set entries. Bindings 3..17 are the same wind + lattice block for every tracer, so
## only the source, the destination and the settled-phase channel differ between callers. `deposit` is
## unwritten when the push constant's `deposit` is false, but the layout still requires a buffer there.
static func bindings(bufs: Dictionary, tracer_in: RID, tracer_out: RID, deposit: RID) -> Array:
	return [
		[0, tracer_in], [1, tracer_out], [2, deposit],
		[3, _buf(bufs, "solid")],
		[4, _buf(bufs, "vel_x")], [5, _buf(bufs, "vel_y")], [6, _buf(bufs, "vel_z")],
		[15, _buf(bufs, "nbr")],
		[16, _buf(bufs, "link_tan")],     # per-column link directions in each cell's own tangent frame
		[17, _buf(bufs, "solid_angle")],  # per-column solid angle: the gather crosses cells of different volume
	]


static func _buf(bufs: Dictionary, key: String) -> RID:
	var v: Variant = bufs.get(key, RID())
	return v if v is RID else RID()


## Params { uint cell_count; uint depth; float k; float settle_v; float diffuse; uint deposit; uint offset;
## float decay; float core_radius; float cell_size; } — 40 bytes. `settle_v` is m/s, signed; `deposit` 1 puts
## settled material into the deposit channel; `core_radius`/`cell_size` size the cells the gather moves
## matter between, in model units.
static func push_constant(cc: int, depth: int, k: float, settle_v: float, diffuse: float,
		deposit: bool, core_radius: float, cell_size: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(40)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k)
	pc.encode_float(12, settle_v)
	pc.encode_float(16, diffuse)
	pc.encode_u32(20, 1 if deposit else 0)
	pc.encode_u32(24, 0)
	pc.encode_float(28, 0.0)
	pc.encode_float(32, core_radius)
	pc.encode_float(36, cell_size)
	return pc
