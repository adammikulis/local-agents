extends RefCounted

## The one airborne-tracer transport kernel: its path, its push constant, and the settling law every tracer
## enters it with. Gases, atmospheric moisture and dust all go through it; the only per-tracer terms are the
## settling velocity and whether the tracer has a settled phase to deposit into.

const KERNEL_PATH: String = "res://addons/local_agents/sim/material/kernels3d/tracer_transport_sphere3d.glsl"

## Symmetric eddy-mixing share per open neighbour. A property of the flow, not of what is suspended in it,
## so every tracer the kernel carries uses this one value.
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
static func dust_settle_v(g_m_s2: float) -> float:
	return LAPhysical.stokes_settling_velocity(LAPhysical.GRAIN_D_UPLAND_M,
			LAPhysical.AIR_DENSITY_KG_M3, LAPhysical.AIR_DYNAMIC_VISCOSITY_PA_S, g_m_s2)


## Lateral Courant factor k_lat = dt/dx: real seconds per field step over the lateral spacing in real metres.
## The velocity field is m/s, so dividing by a model-unit spacing would pin every cell against the CFL cap.
## The kernel rescales this per radial face from the shell table, so only the LATERAL reference is passed.
static func courant(lat_size_model_units: float) -> float:
	var lat_m: float = lat_size_model_units
	if lat_m == 0.0:
		return 0.0
	return LAMaterialFieldSphereStep3D.real_seconds_per_step() / lat_m


## The kernel's uniform-set entries. Bindings 3..40 are the same wind + lattice block for every tracer, so
## only the source, the destination and the settled-phase channel differ between callers.
##
## `deposit` is unwritten when the push constant's `deposit` is false, but the layout still requires a buffer
## there and it must NOT alias `tracer_in` or `tracer_out`: all three are declared `restrict`, which promises
## the driver they do not overlap. A non-depositing caller passes its own scratch.
static func bindings(bufs: Dictionary, tracer_in: RID, tracer_out: RID, deposit: RID) -> Array:
	return [
		[0, tracer_in], [1, tracer_out], [2, deposit],
		[3, _buf(bufs, "solid")],
		[4, _buf(bufs, "vel_x")], [5, _buf(bufs, "vel_y")], [6, _buf(bufs, "vel_z")],
		[15, _buf(bufs, "nbr")],
		[16, _buf(bufs, "link_tan")],      # per-column link directions in each cell's own tangent frame
		[17, _buf(bufs, "link_partner")],  # the donor's own slot for the link back, never arithmetic
		[39, _buf(bufs, "shell")],         # radial face runs, so a radial Courant factor is per-face
		[40, _buf(bufs, "cell_vol")],      # the gather crosses cells of different volume
	]


static func _buf(bufs: Dictionary, key: String) -> RID:
	var v: Variant = bufs.get(key, RID())
	return v if v is RID else RID()


## Params { uint cell_count; uint depth; float k_lat; float settle_v; float diffuse; uint deposit;
## uint offset; float decay; float lat_ref; } — 36 bytes. `settle_v` is m/s, signed; `deposit` 1 puts settled
## material into the deposit channel; `lat_ref` is the lateral spacing `k_lat` was divided by, model units.
static func push_constant(cc: int, depth: int, k_lat: float, settle_v: float, diffuse: float,
		deposit: bool, lat_ref: float) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(36)
	pc.encode_u32(0, cc)
	pc.encode_u32(4, depth)
	pc.encode_float(8, k_lat)
	pc.encode_float(12, settle_v)
	pc.encode_float(16, diffuse)
	pc.encode_u32(20, 1 if deposit else 0)
	pc.encode_u32(24, 0)
	pc.encode_float(28, 0.0)
	pc.encode_float(32, lat_ref)
	return pc
