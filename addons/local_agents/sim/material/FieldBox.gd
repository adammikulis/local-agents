class_name LocalAgentFieldBox
extends Node3D

## LocalAgentFieldBox — the material field sandbox as a node you can DROP INTO A SCENE.
##
## Drag this in, press play, and you get a volumetric MaterialField in BOX mode (setup_dims) with a heat
## source at its floor and a plane of cubes tinted by the live temperature, so you can watch warmth diffuse
## and rise. Everything the code-only demo did by hand — sizing the volume, injecting heat, sampling
## temperatures back out, colouring the slice — is an inspector property here.
##
## It OWNS a LAMaterialField3D as a child rather than extending it: the field script is a designated
## extract-only hub, so the inspector surface lives out here and the field stays untouched.
##
## Box mode is a pure-CPU substrate: LAMaterialField3D._physics_process routes a non-sphere field to
## LAMaterialFieldBoxStep3D, a CPU thermal step, and never creates the RenderingDevice that the
## cubed-sphere path uses. So the simulation itself runs anywhere, headless included; only the slice
## VISUAL needs a display, and it is skipped (and reported) when there is none.
##
## Coordinates are LOCAL to this node: the field does maths in its own space, so the box and its cubes
## move with this node's transform together.
##
## Pair it with a LocalAgentDemoHarness (report_source = this node) for the repo's standard
## `-- --run-frames=N` report line.
## (Explicit types only — project rule: no ':=' inferred typing.)

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")

@export_group("Volume")
## Size of the simulated box in world units: width (x) x height (y) x depth (z).
## Read once when the node starts; changing it later does not resize a running field.
@export var extent: Vector3 = Vector3(60.0, 40.0, 60.0)
## Field cell size in world units. extent / cell_size cells per axis, so smaller is finer and slower.
## Read once when the node starts.
@export_range(0.5, 20.0, 0.5, "suffix:m") var cell_size: float = 5.0
## Shifts the box relative to this node, in world units. At zero the box is centred on x/z with the
## centres of its floor cells sitting at y = 0. Read once when the node starts.
@export var origin_offset: Vector3 = Vector3.ZERO

@export_group("Heat source")
## Run the built-in floor heat source. Turn it off for an inert volume you drive yourself by calling
## add_heat() on field().
@export var heat_enabled: bool = true
## Degrees C injected per frame per source cell during the opening burst.
@export_range(0.0, 500.0, 1.0, "suffix:C") var heat_per_frame: float = 40.0
## Frames the source runs before switching off, after which you watch the heat flow and settle.
## 0 = never stop.
@export_range(0, 6000, 1, "suffix:frames") var heat_burst_frames: int = 40
## Source footprint in cells, centred on the floor: how many cells wide (x), tall (y) and deep (z) the
## heated block is.
@export var heat_source_cells: Vector3i = Vector3i(3, 1, 3)

@export_group("Slice view")
## A plane of cubes tinted by live temperature. This is what makes the field visible.
@export var show_slice: bool = true
## Axis the slice plane cuts across. "Z" gives the classic vertical wall facing the camera; "Y" gives a
## horizontal floor plan.
@export_enum("X", "Y", "Z") var slice_axis: String = "Z"
## Where the slice sits along slice_axis: 0 = the low face of the box, 1 = the high face.
@export_range(0.0, 1.0, 0.01) var slice_position: float = 0.5
## Cube edge as a fraction of cell_size. 1.0 = cubes touch; lower leaves gaps you can see through.
@export_range(0.05, 1.0, 0.05) var cube_fill: float = 0.85
## Temperature above ambient, in degrees C, that reaches hot_color. Smaller = a more sensitive display.
@export_range(1.0, 400.0, 1.0, "suffix:C") var color_span: float = 60.0
## Colour of a cell sitting at ambient temperature.
@export_color_no_alpha var cold_color: Color = Color(0.15, 0.2, 0.5)
## Colour of a cell color_span degrees above ambient (and anything hotter).
@export_color_no_alpha var hot_color: Color = Color(1.0, 0.35, 0.1)

var _field = null                                              # LAMaterialField3D child (box mode)
var _dx: int = 0
var _dy: int = 0
var _dz: int = 0
var _frame: int = 0
var _top_start: float = 0.0

# ONE MultiMeshInstance3D draws the whole slice: a single node and a single draw call for every cell,
# with per-instance colours updated in place each frame instead of N nodes each owning a material.
var _mm_node: MultiMeshInstance3D = null
var _multimesh: MultiMesh = null
var _cube_mesh: BoxMesh = null
var _slice_points: PackedVector3Array = PackedVector3Array()   # sample point per slice instance
var _slice_key: String = ""                                    # axis+index the current instances were built for
var _no_slice_reason: String = ""                              # non-empty when the visual was skipped

var _source_points: PackedVector3Array = PackedVector3Array()  # heat-source cell centres
var _source_key: Vector3i = Vector3i(-1, -1, -1)


func _ready() -> void:
	_build_field()
	_rebuild_source_points()
	_top_start = _sample(_dx / 2, _dy - 1, _dz / 2)


## The LAMaterialField3D this node owns. Call add_heat(), temp_at(), add_water_cell() and friends on it
## to drive the volume yourself.
func field() -> Node:
	return _field


## Cell counts per axis, as chosen by extent / cell_size.
func cell_dims() -> Vector3i:
	return Vector3i(_dx, _dy, _dz)


func _build_field() -> void:
	_field = MaterialFieldScript.new()
	_field.name = "MaterialField"
	add_child(_field)
	_dx = maxi(1, int(round(extent.x / cell_size)))
	_dy = maxi(1, int(round(extent.y / cell_size)))
	_dz = maxi(1, int(round(extent.z / cell_size)))
	var origin: Vector3 = Vector3(-0.5 * extent.x, 0.0, -0.5 * extent.z) + origin_offset
	_field.setup_dims(_dx, _dy, _dz, cell_size, origin)


# Cell centre straight from the field, so a point handed back to temp_at()/add_heat() lands on exactly
# the cell it came from (the field's world_to_cell is the inverse of this).
func _cell_point(ix: int, iy: int, iz: int) -> Vector3:
	return _field.cell_world_pos(clampi(ix, 0, _dx - 1), clampi(iy, 0, _dy - 1), clampi(iz, 0, _dz - 1))


func _sample(ix: int, iy: int, iz: int) -> float:
	if _field == null:
		return 0.0
	return _field.temp_at(_cell_point(ix, iy, iz))


func _process(_delta: float) -> void:
	if _field == null:
		return
	_frame += 1
	if heat_enabled and heat_per_frame != 0.0 and (heat_burst_frames <= 0 or _frame <= heat_burst_frames):
		if _source_key != heat_source_cells:
			_rebuild_source_points()
		for p in _source_points:
			_field.add_heat(p, heat_per_frame)
	_update_slice()


# The heated block: heat_source_cells wide/tall/deep, centred on x/z, sitting on the floor (iy from 0).
func _rebuild_source_points() -> void:
	_source_key = heat_source_cells
	_source_points = PackedVector3Array()
	var wx: int = clampi(heat_source_cells.x, 1, _dx)
	var wy: int = clampi(heat_source_cells.y, 1, _dy)
	var wz: int = clampi(heat_source_cells.z, 1, _dz)
	var x0: int = clampi((_dx - wx) / 2, 0, _dx - 1)
	var z0: int = clampi((_dz - wz) / 2, 0, _dz - 1)
	for iy in range(wy):
		for iz in range(wz):
			for ix in range(wx):
				_source_points.append(_cell_point(x0 + ix, iy, z0 + iz))


# --- Slice visual ------------------------------------------------------------

func _update_slice() -> void:
	if not show_slice:
		if _mm_node != null:
			_mm_node.visible = false
		return
	if not _ensure_slice():
		return
	_mm_node.visible = true
	var edge: float = cell_size * cube_fill
	if not is_equal_approx(_cube_mesh.size.x, edge):
		_cube_mesh.size = Vector3(edge, edge, edge)
	var ambient: float = _field.INITIAL_TEMP
	var span: float = maxf(0.01, color_span)
	for i in range(_slice_points.size()):
		var t: float = _field.temp_at(_slice_points[i])
		var f: float = clampf((t - ambient) / span, 0.0, 1.0)
		_multimesh.set_instance_color(i, cold_color.lerp(hot_color, f))


# True once the slice exists and matches the current axis/position. Returns false when there is nothing
# to draw into: a headless run has no display server, so the visual is skipped and reported instead.
func _ensure_slice() -> bool:
	if _no_slice_reason != "":
		return false
	if _mm_node == null:
		if DisplayServer.get_name() == "headless":
			_no_slice_reason = "no display server (headless); simulation still runs"
			return false
		_build_slice_node()
	var key: String = "%s:%d" % [slice_axis, _slice_index()]
	if key != _slice_key:
		_rebuild_slice_instances(key)
	return _slice_points.size() > 0


# One MultiMeshInstance3D, one BoxMesh, one unshaded vertex-colour material. Unshaded so the temperature
# colours read the same with or without a light in the scene you dropped this into.
func _build_slice_node() -> void:
	_cube_mesh = BoxMesh.new()
	var edge: float = cell_size * cube_fill
	_cube_mesh.size = Vector3(edge, edge, edge)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	_cube_mesh.material = mat
	_multimesh = MultiMesh.new()
	# Format flags must be set while the buffer is still empty; instance_count may change afterwards.
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	_multimesh.mesh = _cube_mesh
	_mm_node = MultiMeshInstance3D.new()
	_mm_node.name = "FieldSlice"
	_mm_node.multimesh = _multimesh
	_mm_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm_node)


func _slice_index() -> int:
	var span: int = _dz
	if slice_axis == "X":
		span = _dx
	elif slice_axis == "Y":
		span = _dy
	return clampi(int(round(slice_position * float(span - 1))), 0, span - 1)


# Lay out the plane of cells for the current axis + index: transforms are written ONCE here, only the
# per-instance colours are touched per frame.
func _rebuild_slice_instances(key: String) -> void:
	_slice_key = key
	var fixed: int = _slice_index()
	_slice_points = PackedVector3Array()
	if slice_axis == "X":
		for iy in range(_dy):
			for iz in range(_dz):
				_slice_points.append(_cell_point(fixed, iy, iz))
	elif slice_axis == "Y":
		for iz in range(_dz):
			for ix in range(_dx):
				_slice_points.append(_cell_point(ix, fixed, iz))
	else:
		for iy in range(_dy):
			for ix in range(_dx):
				_slice_points.append(_cell_point(ix, iy, fixed))
	_multimesh.instance_count = _slice_points.size()
	for i in range(_slice_points.size()):
		_multimesh.set_instance_transform(i, Transform3D(Basis(), _slice_points[i]))
		_multimesh.set_instance_color(i, cold_color)


# --- Report ------------------------------------------------------------------

## Payload for a LocalAgentDemoHarness pointed at this node: the box size, the temperature at the top of
## the volume when the run started versus now, and whether the heat actually travelled up there.
func demo_report() -> Dictionary:
	if _field == null:
		return {"frames": _frame, "cells": 0, "top_start": 0.0, "top_now": 0.0, "bottom_now": 0.0, "flowed": false}
	var top_now: float = _sample(_dx / 2, _dy - 1, _dz / 2)
	var bottom_now: float = _sample(_dx / 2, 0, _dz / 2)
	return {
		"frames": _frame,
		"cells": _dx * _dy * _dz,
		"dims": "%dx%dx%d" % [_dx, _dy, _dz],
		"top_start": snappedf(_top_start, 0.01),
		"top_now": snappedf(top_now, 0.01),
		"bottom_now": snappedf(bottom_now, 0.01),
		"flowed": top_now > _top_start + 0.5,
		"slice_instances": _slice_points.size(),
		"slice_skipped": _no_slice_reason,
	}
