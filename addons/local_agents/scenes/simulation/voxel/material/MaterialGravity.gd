class_name LAMaterialGravity
extends RefCounted

## Ground-fracture concern of the MaterialField.
##
## When the ground is DISTURBED (a meteor blast, an earthquake, a strong impact) it FRACTURES: the
## rock CRACKS and breaks apart. We model that by CARVING — cutting a few cracks/fissures out of the
## terrain SDF radiating from the disturbance — never by ADDING matter. The previous version wrote a
## settled height field back with fill_sphere, which raised ground by stamping literal balls of rock
## (rounded SPHERE domes — the "grey zit bubble" bug); reshaping solid rock by adding spheres is the
## wrong primitive. Carving removes material, so it can only ever open cracks/pits, never bulge.
## Stronger disturbances open more + deeper cracks. (Physical chunk debris + real fracture chips are a
## natural next step, reusing the actor debris spawner; this pass does the terrain crack carving.)
## (Explicit types only — project rule: no ':=' inferred typing.)

const BASE_CRACKS: int = 2                 # cracks at minimum strength; scales up with strength
const CRACK_RADIUS: float = 1.1            # max carve radius along a crack (near the centre)
const CRACK_MAX_EDITS: int = 90            # cap carves per disturbance (bounds the hitch)

var _f = null                              # LAMaterialField (shared grid back-reference)
var _slumps: int = 0                       # diagnostic: cracks carved


func setup(field) -> void:
	_f = field


func slump_count() -> int:
	return _slumps


## FRACTURE the ground over a region: carve a handful of cracks radiating from `world_pos`, narrowing
## and shallowing outward, so the rock reads as split/broken. `strength` (~0..3, e.g. meteor size)
## scales how many cracks and how deep. CARVE-ONLY — it removes rock, so it never domes.
func disturb_terrain(world_pos: Vector3, radius: float, strength: float) -> void:
	var terrain = _f._terrain
	if terrain == null or not terrain.has_method("carve_sphere") or not terrain.has_method("surface_height"):
		return
	var s: float = clampf(strength, 0.1, 3.0)
	var cracks: int = BASE_CRACKS + int(round(s * 2.0))
	var half: float = maxf(_f._cell_size * 0.5, 0.5)
	var edits: int = 0
	for c in range(cracks):
		if edits >= CRACK_MAX_EDITS:
			break
		var ang: float = randf() * TAU
		var dir: Vector3 = Vector3(cos(ang), 0.0, sin(ang))
		var length: float = radius * randf_range(0.45, 1.0)
		var steps: int = maxi(2, int(length / half))
		var p: Vector3 = world_pos
		for k in range(steps):
			if edits >= CRACK_MAX_EDITS:
				break
			p += dir * half
			var gy = terrain.surface_height(p.x, p.z)
			if typeof(gy) != TYPE_FLOAT and typeof(gy) != TYPE_INT:
				continue
			var gyf: float = float(gy)
			if is_nan(gyf) or is_inf(gyf):
				continue
			var taper: float = 1.0 - float(k) / float(steps)           # crack narrows/shallows outward
			var r: float = clampf((0.4 + s * 0.5) * taper, 0.3, CRACK_RADIUS)
			# Carve slightly BELOW the surface so it opens a fissure/gouge rather than nicking the top.
			terrain.carve_sphere(Vector3(p.x, gyf - r * 0.3, p.z), r)
			edits += 1
		_slumps += 1
