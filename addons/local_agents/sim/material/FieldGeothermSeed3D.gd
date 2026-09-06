class_name LAFieldGeothermSeed
extends RefCounted

## Radial seeding geotherm: conductive lithosphere, mantle adiabat, core-mantle jump, core adiabat.


## The profile and the radius it spans; empty when the body cannot be laid out.
static func profile(f, t_surface_c: float) -> Dictionary:
	if f._body == null or not f._body.has_method("radius"):
		push_error("LAFieldGeothermSeed: no declared body, so there is no depth to lay a geotherm along.")
		return {}
	var r_body: float = float(f._body.radius())
	if r_body <= 0.0:
		push_error("LAFieldGeothermSeed: the body declares no radius.")
		return {}
	var prof: PackedFloat32Array = profile_k(r_body, t_surface_c)
	if prof.is_empty():
		return {}
	return {"profile": prof, "r_body": r_body, "t_surface_c": t_surface_c}


## T(r) in kelvin from the centre to the surface on the body's own radial profile, LAPlanetComposition's.
static func profile_k(r_body: float, t_surface_c: float) -> PackedFloat32Array:
	return LAPlanetComposition.geotherm_k(r_body, t_surface_c)
