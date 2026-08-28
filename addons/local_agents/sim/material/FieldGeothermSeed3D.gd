class_name LAFieldGeothermSeed
extends RefCounted

## Radial seeding geotherm: conductive lithosphere, mantle adiabat, core-mantle jump, core adiabat.

const SAMPLES: int = 4096


## The profile and the radius it spans; empty when the body cannot be laid out.
static func profile(f, t_surface_c: float) -> Dictionary:
	if f._body == null or not f._body.has_method("radius"):
		push_error("LAFieldGeothermSeed: no declared body, so there is no depth to lay a geotherm along.")
		return {}
	var r_body: float = float(f._body.radius())
	if r_body <= 0.0:
		push_error("LAFieldGeothermSeed: the body declares no radius.")
		return {}
	var prof: PackedFloat32Array = _profile_k(r_body, t_surface_c)
	if prof.is_empty():
		return {}
	return {"profile": prof, "r_body": r_body, "t_surface_c": t_surface_c}


## Seeding temperature, C, of a cell at radius `r` from the body centre.
static func temperature_c_at(geo: Dictionary, r: float) -> float:
	var r_body: float = float(geo["r_body"])
	if r >= r_body:
		return float(geo["t_surface_c"])
	var prof: PackedFloat32Array = geo["profile"]
	var x: float = r / r_body * float(SAMPLES - 1)
	var i: int = clampi(int(floor(x)), 0, SAMPLES - 2)
	return lerpf(prof[i], prof[i + 1], x - float(i)) - LAPhysical.KELVIN_OFFSET


## T(r) in kelvin at SAMPLES radii from the centre to the surface.
static func _profile_k(r_body: float, t_surface_c: float) -> PackedFloat32Array:
	var table: Dictionary = LASubstances.table()
	var rock: Dictionary = table.get("silicate", {})
	var metal: Dictionary = table.get("metal", {})
	if rock.is_empty() or metal.is_empty():
		push_error("LAFieldGeothermSeed: LASubstances carries no silicate or no metal entry.")
		return PackedFloat32Array()
	var rho_m: float = float(rock.get("density", 0.0))
	var rho_c: float = float(metal.get("density", 0.0))
	var cp_m: float = float(rock.get("specific_heat", 0.0))
	var cp_c: float = float(metal.get("specific_heat", 0.0))
	var k_m: float = float(rock.get("conductivity", 0.0))
	if rho_m <= 0.0 or rho_c <= 0.0 or cp_m <= 0.0 or cp_c <= 0.0 or k_m <= 0.0:
		push_error("LAFieldGeothermSeed: the silicate or metal entry lacks a density, heat capacity or conductivity.")
		return PackedFloat32Array()
	var alpha_m: float = float(rock.get("expansion_per_k", 0.0))
	var alpha_c: float = float(metal.get("expansion_per_k", 0.0))
	var r_core: float = r_body * float(LAPlanetComposition.core_radius_frac(t_surface_c, LAPhysical.STANDARD_PRESSURE_PA))
	# Radiogenic power of the rock at the run's epoch, W/m^3, for the conductive layer's own heating.
	var a_w_m3: float = float(LARadiogenicDecay.heat_w_kg_of(rock.get("traces", {}), LARadiogenicDecay.epoch_years())) * rho_m
	var g_const: float = LAPhysical.GRAVITATIONAL_CONSTANT
	var m_core: float = 4.0 / 3.0 * PI * r_core * r_core * r_core * rho_c
	var t_surface_k: float = t_surface_c + LAPhysical.KELVIN_OFFSET
	var dr: float = r_body / float(SAMPLES - 1)
	var prof: PackedFloat32Array = PackedFloat32Array()
	prof.resize(SAMPLES)
	# Down from the surface: the conductive geotherm until it meets the mantle adiabat.
	var t_ad: float = LAPhysical.MANTLE_POTENTIAL_TEMP_K
	var i_core: int = clampi(int(round(r_core / dr)), 0, SAMPLES - 1)
	for i in range(SAMPLES - 1, i_core - 1, -1):
		var r: float = float(i) * dr
		var z: float = r_body - r
		var t_cond: float = t_surface_k + LAPhysical.SURFACE_HEAT_FLOW_W_M2 * z / k_m - a_w_m3 * z * z / (2.0 * k_m)
		prof[i] = minf(t_cond, t_ad)
		var m_in: float = m_core + 4.0 / 3.0 * PI * (r * r * r - r_core * r_core * r_core) * rho_m
		var g: float = g_const * m_in / maxf(r * r, 1.0)
		t_ad *= 1.0 + alpha_m * g * dr / cp_m
	# The core: the boundary-layer jump, then its own adiabat inward.
	var t_core: float = LAPhysical.CORE_MANTLE_BOUNDARY_TEMP_K
	for i in range(i_core, -1, -1):
		var r: float = float(i) * dr
		prof[i] = t_core
		var g: float = g_const * (4.0 / 3.0 * PI * r * r * r * rho_c) / maxf(r * r, 1.0)
		t_core *= 1.0 + alpha_c * g * dr / cp_c
	return prof
