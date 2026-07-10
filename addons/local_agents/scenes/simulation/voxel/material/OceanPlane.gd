class_name LAOceanPlane
extends MeshInstance3D

## LAOceanPlane — the planet sea, drawn as ONE fixed spherical shell of radius `sea_radius` centred on
## the planet. Land above the shell pokes out; the sea floor below sits submerged. A static shell: no
## camera follow and no per-frame wave/ripple upload — the planet's real (radial) normals are kept and lit
## by a simple translucent water material.
## (Explicit types only — no ':=' inferred typing.)

# SphereMesh radial/ring resolution — high enough to read smooth at planet scale.
const SPHERE_RADIAL_SEGMENTS: int = 96
const SPHERE_RINGS: int = 64


## Build the sea as a FIXED spherical shell of radius `sea_radius` centred on `center` (the planet
## centre = world origin). Land above `sea_radius` pokes out; sea floor below is submerged. A finite
## planet sea does NOT follow the camera — it is a static sphere. Added as a child of the caller.
## `transparent` (from the quality preset) chooses the fill cost: an alpha-blended shell reads as
## semi-transparent water but is drawn in the no-early-Z transparent pass, so this planet-filling sphere
## costs ~40 ms of overdraw at 720p on a mid GPU — the single biggest default-frame cost measured. The
## DEFAULT preset therefore builds it OPAQUE (early-Z, no blending): a solid deep-blue sea that looks nearly
## identical at planet scale for a fraction of the cost. Only HIGH keeps the translucent shell.
func setup_sphere(center: Vector3, sea_radius: float, transparent: bool = true) -> void:
	name = "OceanPlane"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# A smooth SphereMesh at planet scale (radius = sea_radius, full height = diameter).
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = sea_radius
	sphere.height = sea_radius * 2.0
	sphere.radial_segments = SPHERE_RADIAL_SEGMENTS
	sphere.rings = SPHERE_RINGS
	mesh = sphere

	# The flat water shader displaces VERTEX.y from world-XZ waves and forces a Y-up normal — both wrong on
	# a sphere (its sides/bottom would light as if facing up). So the shell uses a simple, correct
	# translucent water material that keeps the mesh's real (radial) normals: a deep semi-transparent blue
	# with a low roughness for reflection and a rim sheen for a fresnel-like edge. Reads as calm water while
	# letting land poke through the shell and the sea floor sit submerged.
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if transparent else BaseMaterial3D.TRANSPARENCY_DISABLED
	mat.albedo_color = Color(0.02, 0.16, 0.34, 0.72 if transparent else 1.0)          # deep sea blue (translucent shell on HIGH, opaque otherwise)
	mat.roughness = 0.08
	mat.metallic = 0.0
	mat.metallic_specular = 0.85
	mat.rim_enabled = true                                    # fresnel-like sky sheen at grazing angles
	mat.rim = 0.5
	mat.rim_tint = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	material_override = mat

	# Static shell: fixed at the planet centre, no camera follow, no per-frame wave/ripple upload.
	global_position = center
