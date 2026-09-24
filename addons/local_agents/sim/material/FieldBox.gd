@icon("res://addons/local_agents/icons/local_agent_field.svg")
class_name LocalAgentFieldBox
extends Node3D

## LocalAgentFieldBox: the material field sandbox as a node you can DROP INTO A SCENE.

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")

@export_group("Volume")
## Size of the simulated box in world units: width (x) x height (y) x depth (z).
## Read once when the node starts; changing it later does not resize a running field.
@export var extent: Vector3 = Vector3(60.0, 40.0, 60.0)
## Field cell size in world units. extent / cell_size cells per axis, so smaller is finer and slower.
## Read once when the node starts.
@export_range(0.5, 20.0, 0.5, "suffix:m") var cell_size: float = 5.0
## Shifts the box relative to this node, in world units. At zero the box is centred on the node in x/z
## with its floor at the node's height. The box is axis-aligned. Read once when the node starts.
@export var origin_offset: Vector3 = Vector3.ZERO

@export_group("Heat source")
## Run the built-in floor heat source. Turn it off for an inert volume you drive yourself by calling
## add_heat_energy() on field().
@export var heat_enabled: bool = true
## Power per source cell. A hotplate is watts; how many frames pass while it runs is not its business.
@export_range(0.0, 1.0e6, 1.0, "suffix:W") var heat_source_w: float = 2000.0
## Seconds the source runs before switching off, after which you watch the heat flow and settle.
## 0 = never stop.
@export_range(0.0, 6000.0, 0.1, "suffix:s") var heat_burst_s: float = 10.0
## Source footprint in cells, centred on the floor: how many cells wide (x), tall (y) and deep (z) the
## heated block is.
@export var heat_source_cells: Vector3i = Vector3i(3, 1, 3)

var _field = null                                              # LAMaterialField3D child (box mode)
var _dx: int = 0
var _dy: int = 0
var _dz: int = 0
var _frame: int = 0
var _source_elapsed: float = 0.0    # simulated seconds the heat source has run
var _top_start: float = 0.0

var _source_points: PackedVector3Array = PackedVector3Array()  # heat-source cell centres
var _source_key: Vector3i = Vector3i(-1, -1, -1)


func _ready() -> void:
	_build_field()
	_rebuild_source_points()
	_top_start = _sample(_dx / 2, _dy - 1, _dz / 2)


## The LAMaterialField3D this node owns. Call add_heat_energy(), temp_at() and friends on it
## to drive the volume yourself.
func field() -> Node:
	return _field


## Cells along x, y and z. Zero before the field is built.
func dims() -> Vector3i:
	return Vector3i(_dx, _dy, _dz)


func _build_field() -> void:
	_field = MaterialFieldScript.new()
	_field.name = "MaterialField"
	add_child(_field)
	_dx = maxi(1, int(round(extent.x / cell_size)))
	_dy = maxi(1, int(round(extent.y / cell_size)))
	_dz = maxi(1, int(round(extent.z / cell_size)))
	var origin: Vector3 = global_position + Vector3(-0.5 * extent.x, 0.0, -0.5 * extent.z) + origin_offset
	_field.setup_box(origin, Vector3i(_dx, _dy, _dz), cell_size)


## World centre of cell (ix, iy, iz), straight from the field: temp_at() and add_heat_energy() at this
## point land on exactly that cell.
func cell_point(ix: int, iy: int, iz: int) -> Vector3:
	return _field.cell_world_pos(clampi(ix, 0, _dx - 1), clampi(iy, 0, _dy - 1), clampi(iz, 0, _dz - 1))


func _sample(ix: int, iy: int, iz: int) -> float:
	return _field.temp_at(cell_point(ix, iy, iz))


func _physics_process(delta: float) -> void:
	if _field == null:
		return
	_frame += 1
	_source_elapsed += delta
	if heat_enabled and heat_source_w != 0.0 and (heat_burst_s <= 0.0 or _source_elapsed <= heat_burst_s):
		if _source_key != heat_source_cells:
			_rebuild_source_points()
		var joules: float = heat_source_w * delta
		for p in _source_points:
			_field.add_heat_energy(p, joules)


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
				_source_points.append(cell_point(x0 + ix, iy, z0 + iz))


# --- Report ------------------------------------------------------------------

## Payload for a LocalAgentDemoHarness pointed at this node: the box size, the temperature at the top of
## the volume when the run started versus now, and whether the heat actually travelled up there.
func demo_report() -> Dictionary:
	if _field == null:
		return {"frames": _frame, "cells": 0}
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
	}
