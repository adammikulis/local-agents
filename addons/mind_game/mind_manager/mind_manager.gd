extends Node
class_name MindManager

signal model_changed(model_path)
signal inference_finished(response)
signal inference_failed(error_message)

const DEFAULT_SCRIPT := "res://scripts/run_inference.py"
const PYTHON_ENV_VAR := "LOCAL_AGENTS_PYTHON"

var model_path: String = ""
var inference_script: String = DEFAULT_SCRIPT
var python_executable: String = ""
var last_response: String = ""

func _ready() -> void:
    python_executable = OS.get_environment(PYTHON_ENV_VAR)
    if python_executable == "":
        python_executable = "python3"

func set_inference_script(script_path: String) -> void:
    inference_script = script_path

func set_python_executable(executable: String) -> void:
    python_executable = executable

func load_model(path: String) -> void:
    if path.is_empty():
        emit_signal("inference_failed", "Model path cannot be empty")
        return
    model_path = path
    emit_signal("model_changed", path)

func unload_model() -> void:
    model_path = ""

func generate_response(prompt: String, max_tokens: int = 128, temperature: float = 0.7, system_prompt: String = "You are a helpful assistant.") -> void:
    if model_path.is_empty():
        emit_signal("inference_failed", "No model has been loaded")
        return
    if prompt.strip_edges().is_empty():
        emit_signal("inference_failed", "Prompt cannot be empty")
        return
    var script_path := ProjectSettings.globalize_path(inference_script)
    var model := ProjectSettings.globalize_path(model_path)
    var args := PackedStringArray([script_path, "--model", model, "--prompt", prompt, "--system", system_prompt, "--max-tokens", str(max_tokens), "--temperature", str(temperature)])
    var std_out: Array = []
    var exit_code := OS.execute(python_executable, args, std_out, true)
    if exit_code != 0:
        var error_message := "Inference process failed with exit code %d" % exit_code
        if std_out.size() > 0:
            error_message += ": " + "".join(std_out)
        emit_signal("inference_failed", error_message)
        return
    var response := "\n".join(std_out).strip_edges()
    last_response = response
    emit_signal("inference_finished", response)
