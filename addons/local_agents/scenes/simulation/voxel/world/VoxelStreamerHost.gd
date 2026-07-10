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

	# Consume the ONE emergent phenomenon-event source instead of scanning the world for events itself: the
	# tracker detects eruptions/wildfires/floods/deaths/… from the shared field + ecology and the director
	# just reacts to each event (dissolve-don't-patch / no parallel detection scans).
	var tracker: Node = world.get_node_or_null("EventTracker")
	if tracker != null and _streamer_director.has_method("on_tracked_event"):
		tracker.event_emitted.connect(_streamer_director.on_tracked_event)

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
	_streamer_overlay.visibility_toggled.connect(_on_streamer_visibility)
	_streamer_overlay.set_default_persona(_streamer_persona)
	_streamer_overlay.set_default_avatar(_streamer_avatar_flavor)

	# A freshly built host always starts hidden + compute-gated: it is now built LAZILY the first time the
	# player presses the streamer hotkey (VoxelWorld._ensure_streamer_host), and that same press then toggles
	# it active/shown. Starting inactive here keeps the local LLM + TTS idle until that toggle fires.
	_set_streamer_active(false)


# Swap the streamer between male/female: rebuild the avatar body + switch the TTS voice live.
func _on_streamer_avatar_selected(flavor: String) -> void:
	if _streamer_avatar != null and _streamer_avatar.has_method("set_flavor"):
		_streamer_avatar.set_flavor(flavor)
	if _streamer_voice != null and _streamer_voice.has_method("set_gender"):
		_streamer_voice.set_gender(flavor)


const SETTINGS_PATH: String = "user://local_agents/streamer.cfg"

var _streamer_active: bool = true   # master runtime state: false = hidden AND compute gated off


## Master runtime hide/show toggle (bound to the in-game hotkey via LAVoxelWorld.toggle_streamer). Hiding
## halts commentary generation (director) + TTS (voice) so a hidden streamer burns zero LLM/speech compute;
## showing resumes. The launch-time --no-streamer / LA_NO_STREAMER path (never even built) is separate.
func toggle_streamer() -> void:
	_set_streamer_active(not _streamer_active)
	_save_hidden(not _streamer_active)


# The overlay's own Hide/Show buttons already flipped their visuals; here we gate compute + persist.
func _on_streamer_visibility(on: bool) -> void:
	_set_streamer_active(on, false)
	_save_hidden(not on)


# Apply the active state everywhere: collapse/expand the face-cam, and gate the director + voice compute.
# `drive_overlay` is false when the overlay already collapsed itself (its button path) to avoid redundancy.
func _set_streamer_active(on: bool, drive_overlay: bool = true) -> void:
	_streamer_active = on
	if drive_overlay and _streamer_overlay != null and _streamer_overlay.has_method("set_collapsed"):
		_streamer_overlay.set_collapsed(not on)
	if _streamer_director != null and _streamer_director.has_method("set_enabled"):
		_streamer_director.set_enabled(on)
	if _streamer_voice != null and _streamer_voice.has_method("set_enabled"):
		_streamer_voice.set_enabled(on)


func _load_hidden() -> bool:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return false
	return bool(cfg.get_value("streamer", "hidden", false))


func _save_hidden(hidden: bool) -> void:
	DirAccess.make_dir_recursive_absolute("user://local_agents")
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # keep any other keys
	cfg.set_value("streamer", "hidden", hidden)
	cfg.save(SETTINGS_PATH)


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
