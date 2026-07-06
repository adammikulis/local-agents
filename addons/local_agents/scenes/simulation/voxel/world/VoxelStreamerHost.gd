class_name LAVoxelStreamerHost
extends Node

# Streamer / commentator subsystem for the voxel world, factored out of the root so VoxelWorld stays a
# thin composition/harness root. Owns the lower-right face-cam overlay, the live SubViewport avatar, the
# Piper TTS voice, the local-LLM director brain, and the live scene-energy graph the director reacts to.
# Dependency-free of the LAVoxelWorld type (dynamic access, no cyclic class reference). (Explicit types
# only — project rule: no ':=' inferred typing.)

const StreamerOverlayScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerOverlay.gd")
const StreamerAvatarScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerAvatar.gd")
const StreamerVoiceScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerVoice.gd")
const StreamerDirectorScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/streamer/StreamerDirector.gd")
const EnergyGraphScript: GDScript = preload("res://addons/local_agents/scenes/simulation/voxel/ui/SceneEnergyGraph.gd")

var _streamer_overlay: CanvasLayer = null  # LAStreamerOverlay (lower-right face-cam + caption + toggle)
var _streamer_director: Node = null        # LAStreamerDirector (LLM commentary brain)
var _streamer_avatar: Node = null          # LAStreamerAvatar (live SubViewport portrait)
var _streamer_voice: Node = null           # LAStreamerVoice (Piper TTS)
var _energy_graph: Control = null          # LASceneEnergyGraph (live total-energy overlay + intensity source)
var _streamer_persona: String = "hype"     # default personality; override with --streamer-persona=<id>
var _streamer_avatar_flavor: String = "male"   # "male" | "female"; override with --streamer-avatar=


# Build the streamer overlay + avatar + voice + director + energy graph, parenting them onto the world.
# `world`/`ecology`/`material` feed the energy graph; `persona`/`avatar_flavor` seed the defaults
# (command-line overrides).
func setup(world: Node, ecology: Node, material: Node, persona: String, avatar_flavor: String) -> void:
	_streamer_persona = persona
	_streamer_avatar_flavor = avatar_flavor

	# Overlay first (a CanvasLayer), then the live avatar parented under it so its SubViewport draws.
	_streamer_overlay = StreamerOverlayScript.new()
	_streamer_overlay.name = "StreamerOverlay"
	world.add_child(_streamer_overlay)

	_streamer_avatar = StreamerAvatarScript.new()
	_streamer_avatar.name = "StreamerAvatar"
	_streamer_overlay.add_child(_streamer_avatar)
	_streamer_avatar.setup(_streamer_avatar_flavor)
	_streamer_overlay.bind_avatar(_streamer_avatar)

	_streamer_voice = StreamerVoiceScript.new()
	_streamer_voice.name = "StreamerVoice"
	world.add_child(_streamer_voice)
	# TTS is silenced by default via the muted "Voice" audio bus (see the mixer), not by disabling the
	# voice — so unmuting Voice in the audio menu is all it takes to hear commentary. Text always shows.
	_streamer_voice.setup({"gender": _streamer_avatar_flavor})

	_streamer_director = StreamerDirectorScript.new()
	_streamer_director.name = "StreamerDirector"
	world.add_child(_streamer_director)
	_streamer_director.setup(world, {"voice": _streamer_voice, "persona": _streamer_persona})

	# Live scene-energy graph (kinetic + seismic + thermal) shown top-right — the intensity signal the
	# director reacts to, made visible. The director reads its current total so quips fire on real energy.
	_energy_graph = EnergyGraphScript.new()
	_streamer_overlay.add_child(_energy_graph)
	_energy_graph.setup(world, ecology, material)
	if _streamer_director.has_method("set_energy_source"):
		_streamer_director.set_energy_source(_energy_graph)

	# Wire the loop: director -> caption + speech; UI toggle/persona -> director; speech -> avatar mouth.
	_streamer_director.line_ready.connect(_on_streamer_line)
	_streamer_director.status_changed.connect(_streamer_overlay.set_status)
	_streamer_overlay.enabled_toggled.connect(_on_streamer_enabled)
	_streamer_overlay.persona_selected.connect(_streamer_director.set_persona)
	_streamer_voice.speaking_started.connect(_on_streamer_speaking_started)
	_streamer_voice.speaking_finished.connect(_on_streamer_speaking_finished)
	_streamer_overlay.avatar_selected.connect(_on_streamer_avatar_selected)
	_streamer_overlay.set_default_persona(_streamer_persona)
	_streamer_overlay.set_default_avatar(_streamer_avatar_flavor)


# Swap the streamer between male/female: rebuild the avatar body + switch the TTS voice live.
func _on_streamer_avatar_selected(flavor: String) -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_flavor"):
		_streamer_avatar.set_flavor(flavor)
	if _streamer_voice != null and _streamer_voice.has_method("set_gender"):
		_streamer_voice.set_gender(flavor)


func _on_streamer_line(text: String) -> void:
	if _streamer_overlay != null:
		_streamer_overlay.show_line(text)
	if _streamer_voice != null:
		_streamer_voice.speak(text)
	print("STREAMER_LINE=%s" % text)


func _on_streamer_enabled(on: bool) -> void:
	if _streamer_director != null:
		_streamer_director.set_enabled(on)
	if _streamer_voice != null:
		_streamer_voice.set_enabled(on)


func _on_streamer_speaking_started(_text: String) -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_talking"):
		_streamer_avatar.set_talking(true)


func _on_streamer_speaking_finished() -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_talking"):
		_streamer_avatar.set_talking(false)
