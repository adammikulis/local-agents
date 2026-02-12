@tool
extends Control
class_name LocalAgentsFlowTraversalConfig

const FlowTraversalProfileResourceScript = preload("res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfileResource.gd")
const PROFILE_PATH := "res://addons/local_agents/configuration/parameters/simulation/FlowTraversalProfile_Default.tres"

@onready var _flow_with_speed_bonus: SpinBox = %FlowWithSpeedBonusSpinBox
@onready var _flow_against_speed_penalty: SpinBox = %FlowAgainstSpeedPenaltySpinBox
@onready var _cross_flow_speed_penalty: SpinBox = %CrossFlowSpeedPenaltySpinBox
@onready var _flow_efficiency_bonus: SpinBox = %FlowEfficiencyBonusSpinBox
@onready var _flow_efficiency_penalty: SpinBox = %FlowEfficiencyPenaltySpinBox
@onready var _shallow_water_speed_penalty: SpinBox = %ShallowWaterSpeedPenaltySpinBox
@onready var _floodplain_speed_penalty: SpinBox = %FloodplainSpeedPenaltySpinBox
@onready var _slope_speed_penalty: SpinBox = %SlopeSpeedPenaltySpinBox
@onready var _save_button: Button = %SaveButton
@onready var _reload_button: Button = %ReloadButton
@onready var _reset_button: Button = %ResetDefaultsButton
@onready var _status_label: Label = %StatusLabel

var _profile
var _updating := false

func _ready() -> void:
	_load_profile()
	_bind_signals()
	_refresh_ui()

func reload_profile() -> void:
	_reload_profile()

func _bind_signals() -> void:
	_flow_with_speed_bonus.value_changed.connect(_on_value_changed)
	_flow_against_speed_penalty.value_changed.connect(_on_value_changed)
	_cross_flow_speed_penalty.value_changed.connect(_on_value_changed)
	_flow_efficiency_bonus.value_changed.connect(_on_value_changed)
	_flow_efficiency_penalty.value_changed.connect(_on_value_changed)
	_shallow_water_speed_penalty.value_changed.connect(_on_value_changed)
	_floodplain_speed_penalty.value_changed.connect(_on_value_changed)
	_slope_speed_penalty.value_changed.connect(_on_value_changed)
	_save_button.pressed.connect(_save_profile)
	_reload_button.pressed.connect(_reload_profile)
	_reset_button.pressed.connect(_reset_defaults)

func _load_profile() -> void:
	_profile = load(PROFILE_PATH)
	if _profile == null:
		_profile = FlowTraversalProfileResourceScript.new()
		_set_status("Profile missing. Using in-memory defaults.")
	else:
		_set_status("Loaded profile: %s" % PROFILE_PATH)

func _refresh_ui() -> void:
	if _profile == null:
		return
	_updating = true
	_flow_with_speed_bonus.value = float(_profile.flow_with_speed_bonus)
	_flow_against_speed_penalty.value = float(_profile.flow_against_speed_penalty)
	_cross_flow_speed_penalty.value = float(_profile.cross_flow_speed_penalty)
	_flow_efficiency_bonus.value = float(_profile.flow_efficiency_bonus)
	_flow_efficiency_penalty.value = float(_profile.flow_efficiency_penalty)
	_shallow_water_speed_penalty.value = float(_profile.shallow_water_speed_penalty)
	_floodplain_speed_penalty.value = float(_profile.floodplain_speed_penalty)
	_slope_speed_penalty.value = float(_profile.slope_speed_penalty)
	_updating = false

func _on_value_changed(_value: float) -> void:
	if _updating or _profile == null:
		return
	_profile.flow_with_speed_bonus = _flow_with_speed_bonus.value
	_profile.flow_against_speed_penalty = _flow_against_speed_penalty.value
	_profile.cross_flow_speed_penalty = _cross_flow_speed_penalty.value
	_profile.flow_efficiency_bonus = _flow_efficiency_bonus.value
	_profile.flow_efficiency_penalty = _flow_efficiency_penalty.value
	_profile.shallow_water_speed_penalty = _shallow_water_speed_penalty.value
	_profile.floodplain_speed_penalty = _floodplain_speed_penalty.value
	_profile.slope_speed_penalty = _slope_speed_penalty.value
	_set_status("Unsaved changes")

func _save_profile() -> void:
	if _profile == null:
		return
	var err = ResourceSaver.save(_profile, PROFILE_PATH)
	if err != OK:
		_set_status("Failed to save profile (%d)" % err)
		return
	_set_status("Saved profile")

func _reload_profile() -> void:
	_load_profile()
	_refresh_ui()

func _reset_defaults() -> void:
	_profile = FlowTraversalProfileResourceScript.new()
	_refresh_ui()
	_set_status("Reset to default values (not saved)")

func _set_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
