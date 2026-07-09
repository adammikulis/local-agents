extends Node
class_name LocalAgentsModelDownloadManager

# Runtime (in-game) model download manager.
#
# Fetches a GGUF model straight from its source into user://local_agents/models using an async
# HTTPRequest node (never blocks the main thread). It reuses the shipped model catalog
# (LocalAgentsModelDownloadService + res://addons/local_agents/models/catalog.json) so runtime and
# editor agree on repos/sizes, and reuses LocalAgentsRuntimePaths for the models directory.
#
# Speed/ETA are smoothed with an exponential moving average so the "~2m left" readout does not
# jitter with every network hiccup:  smoothed = alpha*inst + (1 - alpha)*smoothed  (sampled ~1 Hz).
#
# Resume note: HTTPRequest streams to disk via download_file (the only sane path for multi-GB files
# — buffering a whole model in RAM is not acceptable), and download_file truncates its target, so a
# byte-range append/resume is out of scope. "Graceful" here means the installed model is never
# corrupted by a partial transfer: bytes land in a <name>.part file and are only promoted to the
# final path after the size is verified, so a failed/cancelled download leaves the real model
# untouched and a retry simply starts the .part over.

const ModelDownloadService: GDScript = preload("res://addons/local_agents/controllers/ModelDownloadService.gd")
const RuntimePaths: GDScript = preload("res://addons/local_agents/runtime/RuntimePaths.gd")

# Curated, ungated shortlist surfaced in-game (ids resolved from the shipped catalog). Text models
# default to Q4_K_M; the function-calling helper ships at Q8_0. All are login-free public repos.
const CURATED_IDS: Array[String] = [
	"qwen3-0_6b-instruct-q4_k_m",
	"qwen3-1_7b-q4_k_m",
	"qwen3-4b-instruct-q4_k_m",
	"functiongemma-270m-it-q8_0",
]

# EMA smoothing factor for the download-speed estimate (0.15 -> ~1 Hz samples, gentle response).
const SPEED_ALPHA: float = 0.15
# Sample the instantaneous speed roughly once per second.
const SAMPLE_INTERVAL_MS: int = 1000
# A file counts as installed if it is at least this fraction of the catalog's advertised size.
const INSTALLED_SIZE_TOLERANCE: float = 0.98

signal download_started(model_id: String, total_bytes: int)
signal download_progress(model_id: String, received_bytes: int, total_bytes: int, speed_bytes_per_sec: float, eta_seconds: float)
signal download_finished(model_id: String, ok: bool, path: String, error: String)
signal model_installed(model_id: String, path: String)

var _service: LocalAgentsModelDownloadService = ModelDownloadService.new()
var _http: HTTPRequest = null

var _active_id: String = ""
var _active_final_path: String = ""
var _active_part_path: String = ""
var _active_total: int = 0

var _smoothed_speed: float = 0.0
var _last_sample_ms: int = 0
var _last_sample_bytes: int = 0
var _last_received: int = 0

func _ready() -> void:
	set_process(false)

# -- Catalog ------------------------------------------------------------------

# Returns the curated model rows, each enriched with runtime paths + a display string. Missing
# catalog ids are skipped rather than faked, so a stripped catalog simply shows fewer rows.
func catalog() -> Array:
	var rows: Array = []
	for model_id: String in CURATED_IDS:
		var model: Dictionary = _service.find_model(model_id)
		if model.is_empty():
			continue
		rows.append(_enrich(model))
	return rows

func _enrich(model: Dictionary) -> Dictionary:
	var enriched: Dictionary = model.duplicate(true)
	var folder: String = String(model.get("folder", ""))
	var filename: String = String(model.get("filename", ""))
	var rel_dir: String = RuntimePaths.MODELS_USER_ROOT
	if folder != "":
		rel_dir = "%s/%s" % [RuntimePaths.MODELS_USER_ROOT, folder]
	enriched["user_path"] = "%s/%s" % [rel_dir, filename]
	enriched["part_path"] = "%s.part" % enriched["user_path"]
	enriched["display"] = display_line(model)
	return enriched

# Human-facing one-liner, e.g. "Qwen3 1.7B  ·  Q4_K_M  ·  1.03 GB".
func display_line(model: Dictionary) -> String:
	var params: String = String(model.get("parameters", ""))
	var quant: String = String(model.get("quantization", ""))
	var size_pretty: String = String(model.get("size_pretty", ""))
	if size_pretty == "":
		size_pretty = format_bytes(int(model.get("size_bytes", 0)))
	var name: String = String(model.get("label", model.get("id", "model")))
	# The catalog label already carries the quant in parentheses; strip it, keep params + size explicit.
	var head: String = name.replace(" (%s)" % quant, "")
	var parts: Array[String] = []
	if params != "":
		parts.append(params)
	if quant != "":
		parts.append(quant)
	parts.append(size_pretty)
	return "%s  ·  %s" % [head, "  ·  ".join(parts)]

# -- Installed detection ------------------------------------------------------

func is_model_installed(model_id: String) -> bool:
	return installed_path(model_id) != ""

# Returns the on-disk path of an installed model (size-verified), or "" if not present.
func installed_path(model_id: String) -> String:
	var model: Dictionary = _service.find_model(model_id)
	if model.is_empty():
		return ""
	var enriched: Dictionary = _enrich(model)
	var path: String = String(enriched.get("user_path", ""))
	var expected: int = int(model.get("size_bytes", 0))
	if file_matches_size(path, expected, INSTALLED_SIZE_TOLERANCE):
		return path
	return ""

# Existence + size check shared by installed-detection and post-download verification.
static func file_matches_size(path: String, expected_bytes: int, tolerance: float = 0.98) -> bool:
	if path == "":
		return false
	if not FileAccess.file_exists(path):
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var actual: int = int(file.get_length())
	file.close()
	if actual <= 0:
		return false
	if expected_bytes <= 0:
		return true
	return float(actual) >= float(expected_bytes) * tolerance

# -- Download -----------------------------------------------------------------

func is_downloading() -> bool:
	return _active_id != ""

func active_model_id() -> String:
	return _active_id

# Kicks off an async download. Returns false if busy / unknown id / cannot start (e.g. no network).
func start_download(model_id: String) -> bool:
	if is_downloading():
		return false
	var model: Dictionary = _service.find_model(model_id)
	if model.is_empty():
		_emit_finished(model_id, false, "", "unknown_model")
		return false
	var enriched: Dictionary = _enrich(model)
	var url: String = String(enriched.get("download_url", ""))
	if url == "":
		_emit_finished(model_id, false, "", "no_download_url")
		return false

	_active_id = model_id
	_active_final_path = String(enriched.get("user_path", ""))
	_active_part_path = String(enriched.get("part_path", ""))
	_active_total = int(model.get("size_bytes", 0))

	# Ensure the destination directory exists and clear any stale partial transfer.
	var dir_abs: String = ProjectSettings.globalize_path(_active_final_path).get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_abs)
	if FileAccess.file_exists(_active_part_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_active_part_path))

	_ensure_http()
	_http.download_file = _active_part_path
	_http.download_chunk_size = 1 << 20
	_http.use_threads = true

	_smoothed_speed = 0.0
	_last_sample_ms = Time.get_ticks_msec()
	_last_sample_bytes = 0
	_last_received = 0

	var err: int = _http.request(url)
	if err != OK:
		_reset_active()
		_emit_finished(model_id, false, "", "request_error_%d" % err)
		return false

	set_process(true)
	download_started.emit(model_id, _active_total)
	return true

# Cancels the in-flight download and discards its partial file (the real model is untouched).
func cancel() -> void:
	if not is_downloading():
		return
	var model_id: String = _active_id
	var part_path: String = _active_part_path
	if _http != null:
		_http.cancel_request()
	_reset_active()
	_cleanup_part(part_path)
	_emit_finished(model_id, false, "", "cancelled")

func _ensure_http() -> void:
	if _http != null:
		return
	_http = HTTPRequest.new()
	_http.name = "ModelHTTPRequest"
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

func _process(_delta: float) -> void:
	if not is_downloading() or _http == null:
		return
	var received: int = _http.get_downloaded_bytes()
	var body: int = _http.get_body_size()
	var total: int = body if body > 0 else _active_total
	_last_received = received

	var now: int = Time.get_ticks_msec()
	var elapsed: int = now - _last_sample_ms
	if elapsed >= SAMPLE_INTERVAL_MS:
		var inst: float = float(received - _last_sample_bytes) / (float(elapsed) / 1000.0)
		if inst < 0.0:
			inst = 0.0
		if _smoothed_speed <= 0.0:
			_smoothed_speed = inst
		else:
			_smoothed_speed = ema_step(_smoothed_speed, inst, SPEED_ALPHA)
		_last_sample_ms = now
		_last_sample_bytes = received

	var remaining: int = maxi(total - received, 0)
	var eta: float = eta_seconds(remaining, _smoothed_speed)
	download_progress.emit(_active_id, received, total, _smoothed_speed, eta)

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var model_id: String = _active_id
	var part_path: String = _active_part_path
	var final_path: String = _active_final_path
	var expected: int = _active_total
	var body_size: int = _http.get_body_size() if _http != null else -1
	_reset_active()

	if result != HTTPRequest.RESULT_SUCCESS:
		_cleanup_part(part_path)
		_emit_finished(model_id, false, "", "network_error_%d" % result)
		return
	if response_code < 200 or response_code >= 300:
		_cleanup_part(part_path)
		_emit_finished(model_id, false, "", "http_%d" % response_code)
		return

	# Verify the completed transfer against whichever size we trust most.
	var verify_target: int = body_size if body_size > 0 else expected
	if not file_matches_size(part_path, verify_target, INSTALLED_SIZE_TOLERANCE):
		_cleanup_part(part_path)
		_emit_finished(model_id, false, "", "size_mismatch")
		return

	# Promote the verified partial to the real model path.
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
	var rename_err: int = DirAccess.rename_absolute(ProjectSettings.globalize_path(part_path), ProjectSettings.globalize_path(final_path))
	if rename_err != OK:
		_cleanup_part(part_path)
		_emit_finished(model_id, false, "", "promote_error_%d" % rename_err)
		return

	_emit_finished(model_id, true, final_path, "")
	model_installed.emit(model_id, final_path)

func _cleanup_part(part_path: String) -> void:
	if part_path != "" and FileAccess.file_exists(part_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(part_path))

func _reset_active() -> void:
	set_process(false)
	_active_id = ""
	_active_final_path = ""
	_active_part_path = ""
	_active_total = 0

func _emit_finished(model_id: String, ok: bool, path: String, error: String) -> void:
	download_finished.emit(model_id, ok, path, error)

# -- Pure helpers (unit-testable) --------------------------------------------

static func ema_step(prev_smoothed: float, instantaneous: float, alpha: float) -> float:
	return alpha * instantaneous + (1.0 - alpha) * prev_smoothed

static func eta_seconds(remaining_bytes: int, speed_bytes_per_sec: float) -> float:
	if remaining_bytes <= 0:
		return 0.0
	if speed_bytes_per_sec <= 0.0:
		return -1.0
	return float(remaining_bytes) / speed_bytes_per_sec

static func format_eta(seconds: float) -> String:
	if seconds < 0.0:
		return "calculating…"
	if seconds < 1.0:
		return "almost done"
	if seconds < 90.0:
		return "~%ds left" % int(round(seconds))
	if seconds < 5400.0:
		return "~%dm left" % int(round(seconds / 60.0))
	return "~%dh left" % int(round(seconds / 3600.0))

static func format_bytes(amount: int) -> String:
	if amount <= 0:
		return "0 B"
	var units: Array[String] = ["B", "KB", "MB", "GB", "TB"]
	var size: float = float(amount)
	var index: int = 0
	while size >= 1024.0 and index < units.size() - 1:
		size /= 1024.0
		index += 1
	if index <= 1:
		return "%d %s" % [int(round(size)), units[index]]
	return "%.1f %s" % [size, units[index]]

static func format_speed(bytes_per_sec: float) -> String:
	if bytes_per_sec <= 0.0:
		return "--"
	return "%s/s" % format_bytes(int(bytes_per_sec))

# -- Self-test ----------------------------------------------------------------

# Headless verification of the EMA smoothing + the size-based installed detection. Simulates a noisy
# byte stream (bursts and a stall) and asserts the smoothed speed tracks the trend without chasing
# every spike, then round-trips file_matches_size against a real temp file.
static func run_selftest() -> Dictionary:
	var alpha: float = SPEED_ALPHA
	# Instantaneous per-second speeds: steady, a big spike, a stall, then recovery.
	var samples: Array[float] = [1.0e6, 1.0e6, 1.0e6, 8.0e6, 0.0, 1.0e6, 1.0e6, 1.0e6]
	var smoothed: float = samples[0]
	var trace: Array[float] = [smoothed]
	for i: int in range(1, samples.size()):
		smoothed = ema_step(smoothed, samples[i], alpha)
		trace.append(smoothed)

	# Check 1: on the 8 MB/s spike (raw jumps +7 MB/s) the smoothed value moves far less.
	var spike_index: int = 3
	var raw_jump: float = samples[spike_index] - samples[spike_index - 1]
	var smoothed_jump: float = trace[spike_index] - trace[spike_index - 1]
	var damps_spike: bool = smoothed_jump < raw_jump * 0.5

	# Check 2: smoothed stays within the observed min/max envelope (never overshoots the data).
	var lo: float = samples.min()
	var hi: float = samples.max()
	var in_envelope: bool = true
	for value: float in trace:
		if value < lo - 1.0 or value > hi + 1.0:
			in_envelope = false

	# Check 3: on the stall (raw = 0) the smoothed speed decreases but stays positive (no jump to 0).
	var stall_index: int = 4
	var stall_ok: bool = trace[stall_index] < trace[stall_index - 1] and trace[stall_index] > 0.0

	# Check 4: ETA falls out of remaining/speed and formats sanely.
	var eta: float = eta_seconds(60 * 1024 * 1024, 1.0e6)
	var eta_ok: bool = eta > 55.0 and eta < 70.0
	var eta_text_ok: bool = format_eta(eta) == "~63s left" and format_eta(150.0) == "~3m left"
	var eta_stall_ok: bool = eta_seconds(1000, 0.0) < 0.0 and format_eta(-1.0) == "calculating…"

	# Check 5: file_matches_size round-trip on a real temp file.
	var tmp_path: String = "user://local_agents_downloader_selftest.bin"
	var writer: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	var wrote: bool = false
	if writer != null:
		var blob: PackedByteArray = PackedByteArray()
		blob.resize(1000)
		writer.store_buffer(blob)
		writer.close()
		wrote = true
	var detect_full: bool = file_matches_size(tmp_path, 1000, INSTALLED_SIZE_TOLERANCE)      # exact -> installed
	var detect_partial: bool = not file_matches_size(tmp_path, 2000, INSTALLED_SIZE_TOLERANCE) # half-size -> not installed
	var detect_missing: bool = not file_matches_size("user://does_not_exist.bin", 1000)
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))

	var checks: Dictionary = {
		"ema_damps_spike": damps_spike,
		"ema_in_envelope": in_envelope,
		"ema_stall_decays": stall_ok,
		"eta_math": eta_ok,
		"eta_format": eta_text_ok,
		"eta_stall": eta_stall_ok,
		"detect_installed": wrote and detect_full,
		"detect_partial_not_installed": detect_partial,
		"detect_missing_not_installed": detect_missing,
	}
	var ok: bool = true
	for key: String in checks:
		if not bool(checks[key]):
			ok = false
	return {
		"ok": ok,
		"checks": checks,
		"trace": trace,
		"spike_raw_jump": raw_jump,
		"spike_smoothed_jump": smoothed_jump,
	}
