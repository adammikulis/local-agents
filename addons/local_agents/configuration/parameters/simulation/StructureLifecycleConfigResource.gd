extends Resource
class_name LocalAgentsStructureLifecycleConfigResource

@export var schema_version: int = 1
@export var crowding_members_per_hut_threshold: float = 3.2
@export var throughput_expand_threshold: float = 0.95
@export var expand_cooldown_ticks: int = 24
@export var low_throughput_abandon_threshold: float = 0.35
@export var low_path_strength_abandon_threshold: float = 0.18
@export var abandon_sustain_ticks: int = 72
@export var min_huts_per_household: int = 1
@export var max_huts_per_household: int = 8
@export var hut_ring_step: float = 1.8
@export var hut_start_radius: float = 2.3

func to_dict() -> Dictionary:
    return {
        "schema_version": schema_version,
        "crowding_members_per_hut_threshold": crowding_members_per_hut_threshold,
        "throughput_expand_threshold": throughput_expand_threshold,
        "expand_cooldown_ticks": expand_cooldown_ticks,
        "low_throughput_abandon_threshold": low_throughput_abandon_threshold,
        "low_path_strength_abandon_threshold": low_path_strength_abandon_threshold,
        "abandon_sustain_ticks": abandon_sustain_ticks,
        "min_huts_per_household": min_huts_per_household,
        "max_huts_per_household": max_huts_per_household,
        "hut_ring_step": hut_ring_step,
        "hut_start_radius": hut_start_radius,
    }

func from_dict(values: Dictionary) -> void:
    schema_version = int(values.get("schema_version", schema_version))
    crowding_members_per_hut_threshold = maxf(1.0, float(values.get("crowding_members_per_hut_threshold", crowding_members_per_hut_threshold)))
    throughput_expand_threshold = maxf(0.0, float(values.get("throughput_expand_threshold", throughput_expand_threshold)))
    expand_cooldown_ticks = maxi(1, int(values.get("expand_cooldown_ticks", expand_cooldown_ticks)))
    low_throughput_abandon_threshold = maxf(0.0, float(values.get("low_throughput_abandon_threshold", low_throughput_abandon_threshold)))
    low_path_strength_abandon_threshold = clampf(float(values.get("low_path_strength_abandon_threshold", low_path_strength_abandon_threshold)), 0.0, 1.0)
    abandon_sustain_ticks = maxi(1, int(values.get("abandon_sustain_ticks", abandon_sustain_ticks)))
    min_huts_per_household = maxi(0, int(values.get("min_huts_per_household", min_huts_per_household)))
    max_huts_per_household = maxi(min_huts_per_household, int(values.get("max_huts_per_household", max_huts_per_household)))
    hut_ring_step = maxf(0.5, float(values.get("hut_ring_step", hut_ring_step)))
    hut_start_radius = maxf(0.5, float(values.get("hut_start_radius", hut_start_radius)))
