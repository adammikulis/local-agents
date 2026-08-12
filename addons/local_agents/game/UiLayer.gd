class_name LAUiLayer
extends Node


var _world: Node = null
var _sim: LASimulation = null
var _render: LARenderLayer = null
var _input: LAVoxelInputController = null

@onready var _progression: LAGameProgression = $GameProgression
@onready var _hud: CanvasLayer = $Hud
@onready var _game_hud: CanvasLayer = $GameHud
@onready var _time_control: LAVoxelTimeControl = $TimeControl
@onready var _gen_screen: LAGeneratingPlanetScreen = $GeneratingPlanetScreen
@onready var _audio: LAAudioDirector = $AudioDirector
@onready var _audio_ctrl: Node = $AudioController
@onready var _debug: LAVoxelDebugWiring = $DebugWiring
@onready var _brush: Node3D = $SpawnBrush
@onready var _interaction: Node3D = $Interaction
@onready var _companion: Node = $CompanionController
@onready var _thought_panel: CanvasLayer = $CreatureThoughtPanel
@onready var _tutorial: LACampaignTutorial = $CampaignTutorial


func build(world: Node, sim: LASimulation, render: LARenderLayer, input: LAVoxelInputController) -> void:
	_world = world
	_sim = sim
	_render = render
	_input = input
	var camera: Camera3D = render.camera()
	var terrain = sim.terrain()

	_hud.set_status("Streaming terrain...")

	# The speed pill. The clock itself is LASimTimeAuthority, in the simulation — this only shows it.
	_time_control.set_authority(sim.time_authority())
	_time_control.set_camera(camera)
	if sim.timeline() != null:
		_time_control.set_timeline(sim.timeline())

	_audio.configure()
	_audio.set_music_mood({"population": 0, "time_of_day": 0.30, "destruction_intensity": 0.0})
	_audio_ctrl.setup(_world)
	if _hud.has_method("set_audio_director"):
		_hud.set_audio_director(_audio)
	if _hud.has_signal("music_auto_adapt_changed") and _world.has_method("_on_music_auto_adapt_changed"):
		_hud.music_auto_adapt_changed.connect(Callable(_world, "_on_music_auto_adapt_changed"))

	_debug.setup(_world, sim.material_field(), terrain, render.sky_controller(), _hud, _input, sim.ecology())

	_brush.setup(_world, terrain, camera, sim.ecology(), _hud, _audio, sim.actors_root(), sim.disasters())
	_interaction.setup(_world, terrain, camera, sim.ecology(), _hud, _audio, _brush)
	_interaction.set_game_hud(_game_hud)
	_companion.setup(camera, terrain, _hud)
	_interaction.set_companion(_companion)
	if _hud.has_signal("spawn_selected"):
		_hud.spawn_selected.connect(_interaction.on_spawn_selected)
	_interaction.selection_changed.connect(_debug.on_selection_changed)
	_debug.set_interaction(_interaction)
	_thought_panel.setup(_interaction)
	_tutorial.setup(_interaction, _hud, _game_hud, _input, _progression)

	# The input controller parses the command line in every run; its Esc menu and view-controls bar are
	# Controls and exist only here.
	if _input.has_method("build_ui"):
		_input.build_ui()
	# The stings and the status line these sim controllers accept but never require.
	if sim.disasters() != null and sim.disasters().has_method("set_presentation"):
		sim.disasters().set_presentation(camera, _audio)
	if sim.spawn_controller() != null and sim.spawn_controller().has_method("set_presentation"):
		sim.spawn_controller().set_presentation(camera, _hud)


func step(delta: float) -> void:
	if _gen_screen != null and _sim.is_spawned():
		_gen_screen.finish()
		_gen_screen = null
	_interaction.update_hand(delta)
	_interaction.update_selection_ring()
	_brush.update_brush_ring()


func hud() -> CanvasLayer: return _hud
func game_hud() -> CanvasLayer: return _game_hud
func audio() -> LAAudioDirector: return _audio
func debug_wiring() -> LAVoxelDebugWiring: return _debug
func interaction() -> Node3D: return _interaction
func progression() -> LAGameProgression: return _progression
