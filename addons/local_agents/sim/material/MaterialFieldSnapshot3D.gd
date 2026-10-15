class_name LAMaterialFieldSnapshot3D
extends RefCounted

## The seam between the field and LAFieldSnapshot: a handle crosses it, never a cell-sized array.


## Public snapshots require a fully seeded field.
static func is_ready(field) -> bool:
	return device_ready(field) and field._ready_sim


static func device_ready(field) -> bool:
	return field != null and field._gpu != null and field._gpu._rd != null


## Point `store` at this field's device, cells and box, draining any step still in flight first.
static func bind(field, store: LAFieldSnapshot) -> bool:
	if not is_ready(field):
		return false
	return _bind_device(field, store)


static func _bind_device(field, store: LAFieldSnapshot) -> bool:
	if not device_ready(field) or store == null:
		return false
	field._gpu._drain_pending()
	store.bind(field._gpu._rd, field._gpu._bufs,
		LAChannels.channels() + LAMaterialSphereGPU3D.SEED_PRODUCTS,
		field._cell_count, field._grid)
	return true


## Put a held moment back: the device buffers, the CPU mirrors, and every cell awake again.
static func restore(field, store: LAFieldSnapshot, handle: int) -> bool:
	if not bind(field, store):
		return false
	return _apply_restore(field, store, handle)


static func _apply_restore(field, store: LAFieldSnapshot, handle: int) -> bool:
	if not store.restore(handle):
		return false
	store.apply_mirrors(handle, field)
	field._gpu._wake_field()
	field._atmos_dirty = true
	return true


## A moment of the field as bytes, for the one consumer that is a file.
static func to_bytes(field) -> PackedByteArray:
	var store: LAFieldSnapshot = LAFieldSnapshot.new()
	if not bind(field, store):
		return PackedByteArray()
	var handle: int = store.capture()
	return PackedByteArray() if handle < 0 else store.serialize(handle)


## Those bytes put back into the field; false when they hold another world.
static func seed_from_bytes(field, bytes: PackedByteArray) -> bool:
	var store: LAFieldSnapshot = LAFieldSnapshot.new()
	return _bind_device(field, store) and _apply_restore(field, store, store.deserialize(bytes))
