class_name LAVegLedger
extends RefCounted

## Per-world vegetation accounting, one ledger per LAMaterialField3D instance.

var food_held: float = 0.0        # mass standing in live plant nodes' reserves
var food_drawn: float = 0.0       # cumulative mass taken out of the field's biomass channel
var food_returned: float = 0.0    # cumulative mass handed back as detritus
var seed_cost: float = 0.0        # cumulative parent reserve spent on germination
var pollinations: int = 0         # flower visits

var pollinator_index: LASpatialIndex = LASpatialIndex.new()

static var _by_world: Dictionary = {}


## The ledger belonging to the world that owns `field`; key 0 is a world with no field.
static func of(field: Object) -> LAVegLedger:
	var key: int = field.get_instance_id() if field != null else 0
	if not _by_world.has(key):
		_prune()
		_by_world[key] = LAVegLedger.new()
	return _by_world[key]


# Drop ledgers whose world has been freed.
static func _prune() -> void:
	for k in _by_world.keys():
		if int(k) != 0 and not is_instance_id_valid(int(k)):
			_by_world.erase(k)
