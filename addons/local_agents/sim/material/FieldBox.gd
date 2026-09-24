@icon("res://addons/local_agents/icons/local_agent_field.svg")
class_name LocalAgentFieldBox
extends Node3D

## LocalAgentFieldBox: a sealed box of the planet's surface air as a node you can DROP INTO A SCENE, seeded
## and stepped by its own LASimLoop.

const MaterialFieldScript: GDScript = preload("res://addons/local_agents/sim/material/MaterialField3D.gd")

@export_group("World")
## The rung this box runs at, and so which processes it contains. UNSET defers to `--rung=N`, the project
## setting, LA_RUNG and docs/PLAYABLE_RUNG, in that order. Read once when the node starts.
@export var rung: int = LAProcessSet.UNSET

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
## Run the floor heat source once the box is sealed. Turn it off for an inert volume you drive yourself by
## calling add_heat_energy() on field().
@export var heat_enabled: bool = true
## Power per source cell. A hotplate is watts; the box's own clock says how many seconds it ran.
@export_range(0.0, 1.0e6, 1.0, "suffix:W") var heat_source_w: float = 2000.0
## Simulated seconds the source runs from the seal, after which the box keeps what it was given.
## 0 = never stop.
@export_range(0.0, 6000.0, 0.1, "suffix:s") var heat_burst_s: float = 10.0
## Source footprint in cells, centred on the floor: how many cells wide (x), tall (y) and deep (z) the
## heated block is.
@export var heat_source_cells: Vector3i = Vector3i(3, 1, 3)

var _field = null                                              # LAMaterialField3D child (box mode)
var _loop: LASimLoop = null
var _dims: Vector3i = Vector3i.ZERO
var _source_s: float = 0.0          # simulated seconds the heat source has run since the seal

var _source_points: PackedVector3Array = PackedVector3Array()  # heat-source cell centres
var _source_key: Vector3i = Vector3i(-1, -1, -1)


func _ready() -> void:
	if not LAMaterialSphereGPU3D.available():
		push_error("GPU_REQUIRED: LocalAgentFieldBox steps its field on a compute device, and this renderer "
			+ "offers none (a --headless run has none).")
		return
	LAProcessSet.declare_world(rung)
	_build_field()
	_rebuild_source_points()
	_loop = LASimLoop.new()
	_loop.name = "SimLoop"
	add_child(_loop)
	_loop.hold()
	_loop.seeding.connect(func(_tick: int) -> void:
		if _field.step_driver().seed_tick():
			_loop.release())
	_loop.stepped.connect(_heat)
	_loop.stepped.connect(Callable(_field.step_driver(), "step"))


## The LAMaterialField3D this node owns. Call add_heat_energy(), temp_at() and friends on it
## to drive the volume yourself.
func field() -> Node:
	return _field


## Cells along x, y and z. Zero before the field is built.
func dims() -> Vector3i:
	return _dims


## The temperature every cell was seeded at, C.
func seed_temp_c() -> float:
	return LABodySeeds.surface_temp_c()


## Every face shut; the planet's surface air at its surface pressure in every cell.
func _build_field() -> void:
	_field = MaterialFieldScript.new()
	_field.name = "MaterialField"
	_field.set_meta(LAFieldBoundary3D.META_FACES, "shut,shut,shut,shut,shut,shut")
	_field.set_meta(LAMaterialFieldSphereStep3D.FILL_META, {
		"mole_fractions": LAFieldLithostaticSeed.seeded_air_mole_fractions(),
		"pressure_pa": LABodySeeds.surface_pressure_pa()})
	add_child(_field)
	_dims = Vector3i((extent / cell_size).round()).maxi(1)
	var origin: Vector3 = global_position + Vector3(-0.5 * extent.x, 0.0, -0.5 * extent.z) + origin_offset
	_field.setup_box(origin, _dims, cell_size)


## World centre of cell (ix, iy, iz), straight from the field: temp_at() and add_heat_energy() at this
## point land on exactly that cell.
func cell_point(ix: int, iy: int, iz: int) -> Vector3:
	return _field.cell_world_pos(clampi(ix, 0, _dims.x - 1), clampi(iy, 0, _dims.y - 1), clampi(iz, 0, _dims.z - 1))


## One step of the hotplate once the box is sealed: its watts for the part of the step inside the burst.
func _heat(_step: int) -> void:
	if not heat_enabled or heat_source_w == 0.0 or not _field._seal.sealed():
		return
	var dt: float = LASimLoop.step_seconds()
	var on_s: float = dt if heat_burst_s <= 0.0 else clampf(heat_burst_s - _source_s, 0.0, dt)
	_source_s += dt
	if on_s <= 0.0:
		return
	if _source_key != heat_source_cells:
		_rebuild_source_points()
	for p in _source_points:
		_field.add_heat_energy(p, heat_source_w * on_s)


# The heated block: heat_source_cells wide/tall/deep, centred on x/z, sitting on the floor (iy from 0).
func _rebuild_source_points() -> void:
	_source_key = heat_source_cells
	_source_points = PackedVector3Array()
	var wx: int = clampi(heat_source_cells.x, 1, _dims.x)
	var wy: int = clampi(heat_source_cells.y, 1, _dims.y)
	var wz: int = clampi(heat_source_cells.z, 1, _dims.z)
	var x0: int = clampi((_dims.x - wx) / 2, 0, _dims.x - 1)
	var z0: int = clampi((_dims.z - wz) / 2, 0, _dims.z - 1)
	for iy in range(wy):
		for iz in range(wz):
			for ix in range(wx):
				_source_points.append(cell_point(x0 + ix, iy, z0 + iz))


## Payload for a LocalAgentDemoHarness pointed at this node: the step, the seal and what seeding declared,
## the fill, the heat handed in, the seed temperature against the source cell's and the top cell's, the top
## cell's pressure, the channels holding a non-finite cell, and the conservation block.
func demo_report() -> Dictionary:
	var out: Dictionary = {"steps": _loop.step_index() if _loop != null else 0, "cells": _dims.x * _dims.y * _dims.z,
		"dims": "%dx%dx%d" % [_dims.x, _dims.y, _dims.z], "seed_c": seed_temp_c()}
	if _field == null or not _field._ready_sim:
		return out
	var r: Dictionary = _field.report()
	for key in ["world_sealed", "world_created", "creation_after_seal", "inject_energy_j", "conservation",
			"conservation_allowed_rel", "conservation_worst", "conservation_unmeasured"]:
		out[key] = r.get(key)
	out["fill"] = _field.get_meta(LAMaterialFieldSphereStep3D.FILL_META)
	out["source_c"] = _field.temp_at(cell_point(_dims.x / 2, 0, _dims.z / 2))
	out["top_c"] = _field.temp_at(cell_point(_dims.x / 2, _dims.y - 1, _dims.z / 2))
	out["top_pa"] = _field.pressure_at(cell_point(_dims.x / 2, _dims.y - 1, _dims.z / 2))
	out["nonfinite"] = _field._mirrors.nonfinite()
	return out
