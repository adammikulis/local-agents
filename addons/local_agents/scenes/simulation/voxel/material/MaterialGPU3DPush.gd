class_name LAMaterialGPU3DPush
extends RefCounted

## Push-constant ENCODERS for LAMaterialGPU3D, extracted so the hot GPU backend file stays under the size
## gate. Every function is STATIC and takes the gpu instance `g` (LAMaterialGPU3D), reading its captured
## geometry (`g._dim_x/_dim_y/_dim_z/_cell_count`, `g._origin_y/_cell_size/_sea_level`), per-frame scalars
## (`g._solar/_wind/_prevailing/_raining`) and the folded consts (`g.STEP_DT`, `g.ORO_CONDENSE_GAIN`). Each
## returns the packed PackedByteArray the matching kernel's `layout(push_constant)` block expects — the byte
## layout MUST stay in lockstep with the .glsl Params structs. (Explicit types only — no ':=' inferred typing.)


# 16-byte dims-only push constant: dim_x, dim_y, dim_z, cell_count (heat conduction / buoyancy / rain /
# phase / evap / fire — every kernel whose only parameter is the grid shape).
static func dims_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	return pc


static func heat_pc(g) -> PackedByteArray:
	return dims_pc(g)


# Wind PASS B push-constant: dims + prevailing wind (pvx,pvz) + STEP_DT + buoyancy flag (1 = enabled).
static func wind_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, g._prevailing.x)
	pc.encode_float(20, g._prevailing.y)
	pc.encode_float(24, g.STEP_DT)
	pc.encode_u32(28, 1)
	return pc


# Condensation push-constant: dims + the world XZ wind + orographic gain (windward-slope uplift test).
static func condense_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, g._wind.x)
	pc.encode_float(20, g._wind.y)
	pc.encode_float(24, g.ORO_CONDENSE_GAIN)
	pc.encode_float(28, 0.0)
	return pc


# Cooling push-constant: dims + the geometry the sea thermocline profile needs (origin_y/cell_size/sea).
static func cool_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, g._origin_y)
	pc.encode_float(20, g._cell_size)
	pc.encode_float(24, g._sea_level)
	pc.encode_float(28, 0.0)
	return pc


static func solar_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_float(0, g._solar)
	pc.encode_float(4, g._origin_y)
	pc.encode_float(8, g._cell_size)
	pc.encode_float(12, g._sea_level)
	pc.encode_u32(16, g._dim_x)
	pc.encode_u32(20, g._dim_y)
	pc.encode_u32(24, g._dim_z)
	pc.encode_u32(28, g._dim_x * g._dim_z)
	return pc


static func water_pc(g, pass_id: int) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_u32(16, pass_id)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc


# Lava flow shares the water push-constant shape (dims + pass_id).
static func lava_pc(g, pass_id: int) -> PackedByteArray:
	return water_pc(g, pass_id)


# Slump flow shares the water/lava push-constant shape (dims + pass_id).
static func slump_pc(g, pass_id: int) -> PackedByteArray:
	return water_pc(g, pass_id)


# Atmosphere transport push-constant: dims + this field's diffuse/rise fractions + `wdt`, the folded
# wind_gain*STEP_DT/cell_size that turns each cell's LOCAL velocity into a per-step advection share
# (ax = clamp(|vel_x| * wdt, 0, 0.5)).
static func transport_pc(g, diffuse_frac: float, rise_frac: float, wind_gain: float) -> PackedByteArray:
	var cs: float = g._cell_size if g._cell_size > 0.0 else 1.0
	var wdt: float = wind_gain * g.STEP_DT / cs
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, diffuse_frac)
	pc.encode_float(20, rise_frac)
	pc.encode_float(24, wdt)
	pc.encode_float(28, 0.0)
	return pc


# Charge accumulate push-constant: dims + STEP_DT (the per-step gain × dt separation the kernel applies).
static func charge_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, g.STEP_DT)
	pc.encode_float(20, 0.0)
	pc.encode_float(24, 0.0)
	pc.encode_float(28, 0.0)
	return pc


# Dust LOFT push-constant: dims + a RAINING flag (1 = precipitation suppresses all lofting, wet-sand rule).
static func dust_loft_pc(g) -> PackedByteArray:
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_u32(16, 1 if g._raining else 0)
	pc.encode_u32(20, 0)
	pc.encode_u32(24, 0)
	pc.encode_u32(28, 0)
	return pc


# Dust OUTSCALE / TRANSPORT push-constant: dims + k (STEP_DT/cell_size — the Courant factor turning a cell
# velocity into a per-step advection fraction, matching MaterialDust3D `k`).
static func dust_pc(g) -> PackedByteArray:
	var cs: float = g._cell_size if g._cell_size > 0.0 else 1.0
	var pc: PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, g._dim_x)
	pc.encode_u32(4, g._dim_y)
	pc.encode_u32(8, g._dim_z)
	pc.encode_u32(12, g._cell_count)
	pc.encode_float(16, g.STEP_DT / cs)
	pc.encode_float(20, 0.0)
	pc.encode_float(24, 0.0)
	pc.encode_float(28, 0.0)
	return pc
