extends Control

const REMOTE_CATALOG_URL := "https://raw.githubusercontent.com/ggerganov/llama.cpp/master/models/models.json"
const PACKAGED_CATALOG_PATH := "res://local_agents/data/llama_cpp_models.json"
const DEFAULT_CACHE_DIR := "res://.models"
const DOWNLOAD_SCRIPT := "res://scripts/download_llama_cpp_model.py"

@onready var _family_option: OptionButton = %FamilyOption
@onready var _variant_option: OptionButton = %VariantOption
@onready var _artifact_option: OptionButton = %ArtifactOption
@onready var _cache_path: LineEdit = %CachePath
@onready var _status_label: Label = %StatusLabel
@onready var _details_label: RichTextLabel = %DetailsLabel
@onready var _download_button: Button = %DownloadButton
@onready var _refresh_button: Button = %RefreshButton
@onready var _http_request: HTTPRequest = %CatalogRequest

var _catalog: Dictionary = {}
var _index: Dictionary = {}
var _download_thread: Thread
var _catalog_is_remote := false
var _current_variant: Dictionary
var _current_artifact

func _ready() -> void:
    _cache_path.text = ProjectSettings.globalize_path(DEFAULT_CACHE_DIR)
    _family_option.item_selected.connect(_on_family_selected)
    _variant_option.item_selected.connect(_on_variant_selected)
    _artifact_option.item_selected.connect(_on_artifact_selected)
    _download_button.pressed.connect(_on_download_pressed)
    _refresh_button.pressed.connect(_on_refresh_pressed)
    _http_request.request_completed.connect(_on_catalog_request_completed)
    set_process(false)
    _load_packaged_catalog()

func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE:
        if _download_thread and _download_thread.is_alive():
            _download_thread.wait_to_finish()

func _load_packaged_catalog() -> void:
    var file := FileAccess.open(PACKAGED_CATALOG_PATH, FileAccess.READ)
    if not file:
        _status_label.text = "Bundled llama.cpp catalog is unavailable."
        return
    var json_text := file.get_as_text()
    var parsed = JSON.parse_string(json_text)
    if typeof(parsed) != TYPE_DICTIONARY:
        _status_label.text = "Failed to parse bundled llama.cpp catalog."
        return
    _apply_catalog(parsed, "Loaded bundled llama.cpp catalog.", false)

func _apply_catalog(catalog: Dictionary, message: String, is_remote: bool) -> void:
    _catalog = catalog
    _index = _build_catalog_index(catalog)
    _catalog_is_remote = is_remote
    _populate_families()
    _status_label.text = message

func _populate_families() -> void:
    _family_option.clear()
    var family_ids := _index.keys()
    family_ids.sort()
    for family_id in family_ids:
        var variants: Array = _index[family_id]
        var display := family_id
        if variants.size() > 0 and variants[0].has("family_name") and variants[0]["family_name"]:
            display = variants[0]["family_name"]
        var option_index := _family_option.get_item_count()
        _family_option.add_item(display)
        _family_option.set_item_metadata(option_index, family_id)
    _variant_option.clear()
    _artifact_option.clear()
    _details_label.text = ""
    if _family_option.item_count > 0:
        _family_option.select(0)
        _on_family_selected(0)
    else:
        _status_label.text = "No model families available in the catalog."

func _on_family_selected(index: int) -> void:
    var family_id = _family_option.get_item_metadata(index)
    if typeof(family_id) != TYPE_STRING:
        return
    _populate_variants(family_id)

func _populate_variants(family_id: String) -> void:
    _variant_option.clear()
    _current_variant = {}
    var variants: Array = _index.get(family_id, [])
    for variant in variants:
        var display: String = variant.get("display_name", variant.get("variant_id", "Variant"))
        var option_index := _variant_option.get_item_count()
        _variant_option.add_item(display)
        _variant_option.set_item_metadata(option_index, variant)
    _artifact_option.clear()
    _details_label.text = ""
    if _variant_option.item_count > 0:
        _variant_option.select(0)
        _on_variant_selected(0)

func _on_variant_selected(index: int) -> void:
    var variant = _variant_option.get_item_metadata(index)
    if typeof(variant) != TYPE_DICTIONARY:
        return
    _current_variant = variant
    _populate_artifacts(variant)
    _update_variant_details(variant, null)

func _populate_artifacts(variant: Dictionary) -> void:
    _artifact_option.clear()
    _current_artifact = null
    var artifacts: Array = variant.get("artifacts", [])
    for artifact in artifacts:
        var quantization: String = artifact.get("quantization", "")
        var display := quantization if quantization != "" else artifact.get("filename", "Artifact")
        if quantization != "" and artifact.get("filename", "") != "":
            display = "%s (%s)" % [quantization, artifact["filename"]]
        elif artifact.get("filename", "") != "":
            display = artifact["filename"]
        var option_index := _artifact_option.get_item_count()
        _artifact_option.add_item(display)
        _artifact_option.set_item_metadata(option_index, artifact)
    if _artifact_option.item_count > 0:
        _artifact_option.select(0)
        _on_artifact_selected(0)

func _on_artifact_selected(index: int) -> void:
    var artifact = _artifact_option.get_item_metadata(index)
    _current_artifact = artifact
    _update_variant_details(_current_variant, artifact)

func _update_variant_details(variant: Dictionary, artifact: Dictionary) -> void:
    if variant == null:
        _details_label.text = ""
        return
    var lines: Array[String] = []
    lines.append("[b]%s[/b]" % variant.get("display_name", variant.get("variant_id", "Model")))
    if variant.get("parameters"):
        lines.append("Parameters: %s" % str(variant["parameters"]))
    if variant.get("context_length"):
        lines.append("Context length: %s" % str(variant["context_length"]))
    if variant.get("license"):
        lines.append("License: %s" % str(variant["license"]))
    if variant.get("description"):
        lines.append(variant["description"])
    if artifact != null:
        var size_bytes = artifact.get("size_bytes", 0)
        if typeof(size_bytes) == TYPE_INT and size_bytes > 0:
            var size_mb = float(size_bytes) / 1024.0 / 1024.0
            lines.append("Size: %.2f MiB" % size_mb)
        if artifact.get("filename"):
            lines.append("File: %s" % artifact["filename"])
        if artifact.get("quantization"):
            lines.append("Quantization: %s" % artifact["quantization"])
    _details_label.text = "\n".join(lines)

func _on_download_pressed() -> void:
    if _download_thread and _download_thread.is_alive():
        return
    if typeof(_current_variant) != TYPE_DICTIONARY or _current_variant.is_empty():
        _status_label.text = "Select a model variant before downloading."
        return
    var artifact = _current_artifact
    if artifact == null:
        _status_label.text = "Select an artifact to download."
        return
    var family_id = _current_variant.get("family_id")
    var variant_id = _current_variant.get("variant_id")
    var quantization = artifact.get("quantization")
    var cache_dir = _cache_path.text.strip_edges()
    if cache_dir == "":
        cache_dir = ProjectSettings.globalize_path(DEFAULT_CACHE_DIR)
    var python_executable := _resolve_python()
    if python_executable == "":
        _status_label.text = "Python executable could not be determined. Configure LocalAgentManager first."
        return
    var script_path := ProjectSettings.globalize_path(DOWNLOAD_SCRIPT)
    var args := PackedStringArray([script_path, "--family", str(family_id)])
    if variant_id:
        args.push_back("--variant")
        args.push_back(str(variant_id))
    if quantization:
        args.push_back("--quantization")
        args.push_back(str(quantization))
    if cache_dir:
        args.push_back("--cache-dir")
        args.push_back(cache_dir)
    if not _catalog_is_remote:
        args.push_back("--offline")
    _status_label.text = "Downloading model..."
    _set_controls_enabled(false)
    _download_thread = Thread.new()
    _download_thread.start(callable(self, "_download_worker"), [python_executable, args])
    set_process(true)

func _resolve_python() -> String:
    if Engine.has_singleton("LocalAgentManager"):
        var manager = Engine.get_singleton("LocalAgentManager")
        if manager != null:
            var exe = manager.get("python_executable")
            if typeof(exe) == TYPE_STRING and exe != "":
                return exe
    if has_node("/root/LocalAgentManager"):
        var manager_node = get_node("/root/LocalAgentManager")
        if manager_node != null:
            var exe_node = manager_node.get("python_executable")
            if typeof(exe_node) == TYPE_STRING and exe_node != "":
                return exe_node
    return "python3"

func _download_worker(params: Array) -> Dictionary:
    var python_executable: String = params[0]
    var args: PackedStringArray = params[1]
    var output: Array = []
    var exit_code := OS.execute(python_executable, args, output, true, true)
    return {
        "exit_code": exit_code,
        "output": output,
    }

func _process(_delta: float) -> void:
    if _download_thread and not _download_thread.is_alive():
        var result = _download_thread.wait_to_finish()
        _download_thread = null
        _handle_download_result(result)
        set_process(false)

func _handle_download_result(result) -> void:
    _set_controls_enabled(true)
    if result is Dictionary:
        var exit_code: int = result.get("exit_code", -1)
        var output: Array = result.get("output", [])
        if exit_code == 0:
            var message := "Model downloaded successfully."
            if output.size() > 0:
                message = "Saved to: %s" % str(output[-1]).strip_edges()
            _status_label.text = message
            return
        else:
            if output.size() > 0:
                var error_text := PackedStringArray(output).join("\n")
                _status_label.text = "Download failed: %s" % error_text.strip_edges()
                return
    _status_label.text = "Model download failed."

func _set_controls_enabled(enabled: bool) -> void:
    _family_option.disabled = not enabled
    _variant_option.disabled = not enabled
    _artifact_option.disabled = not enabled
    _cache_path.editable = enabled
    _download_button.disabled = not enabled
    var refresh_disabled := not enabled or _http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED
    _refresh_button.disabled = refresh_disabled

func _on_refresh_pressed() -> void:
    if _http_request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
        return
    _status_label.text = "Refreshing catalog..."
    _refresh_button.disabled = true
    var error := _http_request.request(REMOTE_CATALOG_URL)
    if error != OK:
        _refresh_button.disabled = false
        _status_label.text = "Catalog refresh failed to start."

func _on_catalog_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
    _refresh_button.disabled = false
    if response_code != 200:
        _status_label.text = "Catalog refresh failed (HTTP %d)." % response_code
        return
    var text := body.get_string_from_utf8()
    var parsed = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        _status_label.text = "Catalog refresh returned unexpected data."
        return
    _apply_catalog(parsed, "Catalog refreshed from llama.cpp.", true)

func _build_catalog_index(catalog: Dictionary) -> Dictionary:
    var index: Dictionary = {}
    for variant in _iter_variants_from_catalog(catalog):
        var family_id: String = variant.get("family_id", "")
        if family_id == "":
            continue
        if not index.has(family_id):
            index[family_id] = []
        index[family_id].append(variant)
    return index

func _iter_variants_from_catalog(catalog: Dictionary) -> Array:
    var result: Array = []
    var families: Array = []
    if catalog.has("families"):
        var family_entry = catalog["families"]
        if family_entry is Array:
            families = family_entry
        elif family_entry is Dictionary:
            families = family_entry.values()
    elif catalog.has("models") and catalog["models"] is Array:
        families = catalog["models"]
    var family_index := 0
    for entry in families:
        if typeof(entry) != TYPE_DICTIONARY:
            family_index += 1
            continue
        var family_id := _coerce_optional_str(entry.get("id"))
        if family_id == null:
            family_id = _coerce_optional_str(entry.get("slug"))
        if family_id == null:
            family_id = _coerce_optional_str(entry.get("family"))
        if family_id == null:
            family_id = _coerce_optional_str(entry.get("name"))
        if family_id == null:
            family_id = "family-%d" % family_index
        var family_name := _coerce_optional_str(entry.get("display_name"))
        if family_name == null:
            family_name = _coerce_optional_str(entry.get("name"))
        if family_name == null:
            family_name = _coerce_optional_str(entry.get("title"))
        if family_name == null:
            family_name = family_id
        var variants: Array = []
        if entry.has("variants") and entry["variants"] is Array:
            variants = entry["variants"]
        elif entry.has("models") and entry["models"] is Array:
            variants = entry["models"]
        var variant_index := 0
        for variant_entry in variants:
            if typeof(variant_entry) != TYPE_DICTIONARY:
                variant_index += 1
                continue
            var variant_id := _coerce_optional_str(variant_entry.get("id"))
            if variant_id == null:
                variant_id = _coerce_optional_str(variant_entry.get("slug"))
            if variant_id == null:
                variant_id = _coerce_optional_str(variant_entry.get("name"))
            if variant_id == null:
                variant_id = _coerce_optional_str(variant_entry.get("model"))
            if variant_id == null:
                variant_id = "%s-variant-%d" % [family_id, variant_index]
            var display_name := _coerce_optional_str(variant_entry.get("display_name"))
            if display_name == null:
                display_name = _coerce_optional_str(variant_entry.get("name"))
            if display_name == null:
                display_name = _coerce_optional_str(variant_entry.get("title"))
            if display_name == null:
                display_name = variant_id
            var description := _coerce_optional_str(variant_entry.get("description"))
            var license_name := _coerce_optional_str(variant_entry.get("license"))
            var repo_id := _coerce_optional_str(variant_entry.get("repo_id"))
            var parameters := _coerce_optional_str(variant_entry.get("parameters"))
            var context_length := _coerce_optional_int(variant_entry.get("context_length"))
            var files: Array = []
            if variant_entry.has("files") and variant_entry["files"] is Array:
                files = variant_entry["files"]
            elif variant_entry.has("artifacts") and variant_entry["artifacts"] is Array:
                files = variant_entry["artifacts"]
            var artifacts: Array = []
            for file_entry in files:
                if typeof(file_entry) != TYPE_DICTIONARY:
                    continue
                var filename := _coerce_optional_str(file_entry.get("filename"))
                if filename == null:
                    filename = _coerce_optional_str(file_entry.get("name"))
                if filename == null:
                    filename = _coerce_optional_str(file_entry.get("path"))
                if filename == null:
                    continue
                var artifact_repo := _coerce_optional_str(file_entry.get("repo_id"))
                if artifact_repo == null:
                    artifact_repo = repo_id
                var quantization := _coerce_optional_str(file_entry.get("quantization"))
                if quantization == null:
                    quantization = _coerce_optional_str(file_entry.get("variant"))
                if quantization == null:
                    quantization = _coerce_optional_str(file_entry.get("dtype"))
                var file_format := _coerce_optional_str(file_entry.get("format"))
                var size_bytes := _coerce_optional_int(file_entry.get("size_bytes"))
                if size_bytes == null:
                    size_bytes = _coerce_optional_int(file_entry.get("size"))
                if size_bytes == null:
                    size_bytes = _coerce_optional_int(file_entry.get("file_size"))
                var url := _coerce_optional_str(file_entry.get("url"))
                artifacts.append({
                    "filename": filename,
                    "quantization": quantization,
                    "format": file_format,
                    "repo_id": artifact_repo,
                    "url": url,
                    "size_bytes": size_bytes,
                })
            result.append({
                "family_id": family_id,
                "family_name": family_name,
                "variant_id": variant_id,
                "display_name": display_name,
                "description": description,
                "license": license_name,
                "repo_id": repo_id,
                "parameters": parameters,
                "context_length": context_length,
                "artifacts": artifacts,
            })
            variant_index += 1
        family_index += 1
    return result

func _coerce_optional_str(value) -> String?:
    if value == null:
        return null
    var t := typeof(value)
    if t == TYPE_STRING:
        var stripped := (value as String).strip_edges()
        return stripped if stripped != "" else null
    if t == TYPE_BOOL:
        return value ? "true" : "false"
    if t == TYPE_INT or t == TYPE_FLOAT:
        return str(value)
    return str(value)

func _coerce_optional_int(value) -> int?:
    if value == null:
        return null
    var t := typeof(value)
    if t == TYPE_INT:
        return value
    if t == TYPE_FLOAT:
        return int(value)
    if t == TYPE_BOOL:
        return value ? 1 : 0
    if t == TYPE_STRING:
        var stripped := (value as String).strip_edges().replace(",", "")
        if stripped == "":
            return null
        var number := float(stripped)
        return int(number)
    return null
