extends RigidBody3D
class_name FpsLauncherProjectile

@export_range(0.1, 30.0, 0.1) var ttl_seconds: float = 4.0

var _alive_seconds: float = 0.0

func _ready() -> void:
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 1

func _physics_process(delta: float) -> void:
	_alive_seconds += delta
	if _alive_seconds >= ttl_seconds:
		queue_free()

func set_ttl_seconds(value: float) -> void:
	ttl_seconds = maxf(0.1, value)
