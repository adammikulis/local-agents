class_name LAMaterialFieldInject3D
extends RefCounted

## LAMaterialFieldInject3D — the WRITE-side injection + FX API of the dense 3D MaterialField3D, factored
## out so the field node stays a thin simulation/composition core (and under the file-size gate). Holds
## NO state of its own: it reaches into the owning LAMaterialField3D (`_f`) for the shared per-cell arrays
## (`_solid`), geometry (`_dim_x/_dim_y/_dim_z`, `_cell_size`, `_origin`), the terrain SDF (`_terrain`),
## and the field's own cell helpers (`add_water_cell`/`_col_i`/`_surface_iy`/`cell_world_pos`) — exactly as
## the heat / atmosphere / lava concern modules do. The field owns these as its real injection surface
## (this is the same split as MaterialFieldQueries3D / MaterialFieldRender3D, not a compat layer).
## (Explicit types only — no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


# --- Injection API (disasters/flood call these) -----------------------------

## Flood pool-fill: add water only where the ground is at/below the centre column's ground, so a surge
## fills the basin and runs downhill (never climbs a hillside). 3D analogue of the 2.5D add_water_pooled.
func add_water_pooled(center: Vector3, amount: float, radius: float) -> void:
	var ci: int = _f._col_i(center.x, _f._origin.x)
	var ck: int = _f._col_i(center.z, _f._origin.z)
	var center_ground: float = _column_ground_y(ci, ck)
	var cs: float = _f._cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var r2: float = radius * radius
	for dk in range(-cells, cells + 1):
		var iz: int = ck + dk
		if iz < 0 or iz >= _f._dim_z:
			continue
		for di in range(-cells, cells + 1):
			var ix: int = ci + di
			if ix < 0 or ix >= _f._dim_x:
				continue
			var wx: float = _f._origin.x + float(ix) * cs
			var wz: float = _f._origin.z + float(iz) * cs
			var dx: float = wx - center.x
			var dz: float = wz - center.z
			if dx * dx + dz * dz > r2:
				continue
			if _column_ground_y(ix, iz) <= center_ground + 4.0:
				var iy: int = _f._surface_iy(ix, iz)
				if iy >= 0:
					_f.add_water_cell(ix, iy, iz, amount)


# World Y of the top solid (ground) surface in a column, or the bottom if all void.
func _column_ground_y(ix: int, iz: int) -> float:
	for iy in range(_f._dim_y - 1, -1, -1):
		if _f._solid[(iy * _f._dim_z + iz) * _f._dim_x + ix] != 0:
			return _f._origin.y + float(iy) * _f._cell_size
	return _f._origin.y


## Re-sample rock/void from the terrain SDF in a region after an edit (a crater, a lava-built delta).
func resample_terrain(world_pos: Vector3, radius: float) -> void:
	if _f._terrain == null or not _f._terrain.has_method("is_solid"):
		return
	var cs: float = _f._cell_size
	var cells: int = maxi(1, int(ceil(radius / cs)))
	var ci: int = _f._col_i(world_pos.x, _f._origin.x)
	var cj: int = _f._col_i(world_pos.y, _f._origin.y)
	var ck: int = _f._col_i(world_pos.z, _f._origin.z)
	for dj in range(-cells, cells + 1):
		var iy: int = cj + dj
		if iy < 0 or iy >= _f._dim_y:
			continue
		for dk in range(-cells, cells + 1):
			var iz: int = ck + dk
			if iz < 0 or iz >= _f._dim_z:
				continue
			for di in range(-cells, cells + 1):
				var ix: int = ci + di
				if ix < 0 or ix >= _f._dim_x:
					continue
				var i: int = (iy * _f._dim_z + iz) * _f._dim_x + ix
				_f._solid[i] = 1 if _f._terrain.is_solid(_f.cell_world_pos(ix, iy, iz)) else 0


# --- Physical splash droplets (FX) ------------------------------------------

## A few short-lived rigidbody droplets flung from a world point — the splash accent disasters call.
func splash(world_pos: Vector3, strength: float) -> void:
	if not _f.is_inside_tree() or is_nan(world_pos.x):
		return
	var s: float = clampf(strength, 0.1, 4.0)
	var mesh: SphereMesh = SphereMesh.new()
	mesh.radius = 0.12
	mesh.height = 0.24
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.6, 0.9, 0.75)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	for n in range(5):
		var body: RigidBody3D = RigidBody3D.new()
		body.mass = 0.05
		body.collision_mask = 1
		body.collision_layer = 0
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		body.add_child(mi)
		_f.add_child(body)
		body.global_position = world_pos + Vector3(randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))
		var ang: float = randf() * TAU
		body.linear_velocity = Vector3(cos(ang) * randf_range(1.0, 2.5) * s, randf_range(2.5, 4.5) * s, sin(ang) * randf_range(1.0, 2.5) * s)
		var tm: SceneTreeTimer = _f.get_tree().create_timer(2.0)
		tm.timeout.connect(func(): if is_instance_valid(body): body.queue_free())
