class_name LAVegetationRenderer
extends Node3D

## GPU-instanced rendering for the static vegetation (plants + trees). Each plant/tree keeps its own sim
## node (growth, collision, feed, seeding) but DOES NOT own a MeshInstance3D anymore: it registers with this
## renderer and pushes its transform while it is growing (or toppling). All plants of one visual type then
## render in ONE batched MultiMesh draw instead of hundreds of per-node draws — the on-brand GPU-first fix
## for the 256+ vegetation actors that were dominating the draw-call count.
##
## One MultiMeshInstance3D per visual type (id from LAActorModels: "plant", "tree_oak", "tree_pine"). The
## source mesh is baked ONCE from the Kenney glTF, normalized to height 1 and base-anchored, so an actor's
## instance transform is simply its own node transform scaled by its display height — the actor's existing
## growth/topple transform logic is unchanged, only its rendering is decoupled.
##
## Lives UNDER actors_root and its MMIs sit at identity, so a pushed instance transform is the actor's LOCAL
## transform (actors are direct children of actors_root) — vegetation rides the planet frame for free.
##
## LOD / bubbles-of-compute: an actor only pushes while it is CHANGING (growing to maturity, or toppling).
## A mature, static tree/plant costs ZERO per-frame render work — its instance transform is written once and
## left alone. (Explicit types only — project rule: no ':=' .)

const _CHUNK: int = 256                 # capacity growth granularity (instances added per realloc)
const _INITIAL_CAP: int = 512           # starting per-type capacity (covers the default preset with headroom)

# A degenerate (zero-scale) transform collapses a freed instance to nothing on the GPU without shrinking
# the buffer — the slot is recycled via the free list.
const _HIDDEN: Transform3D = Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)

# Prototype meshes are shared across all instances of a type; baked lazily on first register, cached here.
static var _proto_cache: Dictionary = {}


class Batch:
	extends RefCounted
	var mm: MultiMesh = null
	var mmi: MultiMeshInstance3D = null
	var capacity: int = 0
	var used: int = 0                    # high-water slot count allocated
	var free: Array = []                 # recycled slots below the high-water mark
	var xforms: Array = []               # CPU mirror of instance transforms (survives capacity growth)


var _batches: Dictionary = {}           # type id -> Batch


## Register a vegetation actor of `type` (a LAActorModels id). Returns its slot index (>=0) or -1 if the type
## has no model to instance (caller then falls back to its own procedural mesh).
func register(type: String) -> int:
	var b: Batch = _ensure_batch(type)
	if b == null:
		return -1
	var slot: int = -1
	if not b.free.is_empty():
		slot = int(b.free.pop_back())
	else:
		if b.used >= b.capacity:
			_grow(b, b.capacity + _CHUNK)
		slot = b.used
		b.used += 1
		b.mm.visible_instance_count = b.used
	# Start hidden until the actor pushes its first real transform (same frame).
	b.xforms[slot] = _HIDDEN
	b.mm.set_instance_transform(slot, _HIDDEN)
	return slot


## Push an actor's current instance transform (its LOCAL node transform, already scaled by display height).
func set_xform(type: String, slot: int, xf: Transform3D) -> void:
	var b = _batches.get(type, null)
	if b == null or slot < 0 or slot >= b.used:
		return
	b.xforms[slot] = xf
	b.mm.set_instance_transform(slot, xf)


## Release a slot (actor removed / died): hide it and recycle the index for reuse.
func release(type: String, slot: int) -> void:
	var b = _batches.get(type, null)
	if b == null or slot < 0 or slot >= b.used:
		return
	b.xforms[slot] = _HIDDEN
	b.mm.set_instance_transform(slot, _HIDDEN)
	b.free.append(slot)


# --- internals -------------------------------------------------------------

func _ensure_batch(type: String) -> Batch:
	var existing = _batches.get(type, null)
	if existing != null:
		return existing
	var proto: ArrayMesh = _prototype(type)
	if proto == null:
		return null
	var b: Batch = Batch.new()
	b.capacity = _INITIAL_CAP
	b.mm = MultiMesh.new()
	b.mm.transform_format = MultiMesh.TRANSFORM_3D
	b.mm.mesh = proto
	b.mm.instance_count = b.capacity
	b.mm.visible_instance_count = 0
	b.xforms.resize(b.capacity)
	for i in range(b.capacity):
		b.xforms[i] = _HIDDEN
	b.mmi = MultiMeshInstance3D.new()
	b.mmi.name = "Veg_%s" % type
	b.mmi.multimesh = b.mm
	# Static props: no per-instance shadow flicker cost we can't afford, but keep them shadow-casting so the
	# forest reads on the ground like the per-node meshes did.
	add_child(b.mmi)
	_batches[type] = b
	return b


# Grow a batch's instance buffer, preserving existing transforms from the CPU mirror (changing instance_count
# reallocates the GPU buffer, so we re-apply). Rare — happens only when a type outgrows its capacity.
func _grow(b: Batch, new_cap: int) -> void:
	b.capacity = new_cap
	b.xforms.resize(new_cap)
	b.mm.instance_count = new_cap
	for i in range(b.used):
		b.mm.set_instance_transform(i, b.xforms[i])
	b.mm.visible_instance_count = b.used


static func _prototype(type: String) -> ArrayMesh:
	if _proto_cache.has(type):
		return _proto_cache[type]
	var mesh: ArrayMesh = _bake_prototype(type)
	_proto_cache[type] = mesh
	return mesh


# Bake the Kenney model for `type` into ONE ArrayMesh normalized to height 1, base-anchored, with the same
# recolor/tint the per-node path used — so instancing is visually identical, just batched. One surface per
# source mesh surface (each keeps its own material), so a tree stays trunk + foliage coloured correctly.
static func _bake_prototype(type: String) -> ArrayMesh:
	var def: Dictionary = LAActorModels.get_def(type)
	if String(def.get("path", "")).is_empty():
		return null
	var model: Node3D = LAModelVisual.build(def["path"], 1.0, "base", float(def.get("yaw", 0.0)), LAActorModels.tint(type))
	if model == null:
		return null
	LAModelVisual.recolor(model, def.get("recolor", {}))
	var out: ArrayMesh = ArrayMesh.new()
	for mi in LAModelVisual._mesh_instances(model):
		var src: Mesh = (mi as MeshInstance3D).mesh
		if src == null:
			continue
		var rel: Transform3D = model.transform * LAModelVisual._relative_xform(model, mi)
		for si in range(src.get_surface_count()):
			if src.surface_get_primitive_type(si) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays: Array = _transform_arrays(src.surface_get_arrays(si), rel)
			var base: int = out.get_surface_count()
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mat: Material = (mi as MeshInstance3D).get_active_material(si)
			if mat != null:
				out.surface_set_material(base, mat)
	model.free()
	return out


# Bake a surface's vertices/normals into world-of-prototype space by `xf` (vegetation models are uniformly
# scaled, so the basis rotates normals faithfully after re-normalizing).
static func _transform_arrays(arrays: Array, xf: Transform3D) -> Array:
	var out: Array = arrays.duplicate(true)
	var verts = out[Mesh.ARRAY_VERTEX]
	if verts is PackedVector3Array:
		var nv: PackedVector3Array = PackedVector3Array()
		nv.resize(verts.size())
		for i in range(verts.size()):
			nv[i] = xf * verts[i]
		out[Mesh.ARRAY_VERTEX] = nv
	var norms = out[Mesh.ARRAY_NORMAL]
	if norms is PackedVector3Array:
		var nn: PackedVector3Array = PackedVector3Array()
		nn.resize(norms.size())
		for i in range(norms.size()):
			nn[i] = (xf.basis * norms[i]).normalized()
		out[Mesh.ARRAY_NORMAL] = nn
	return out
