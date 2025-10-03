extends Control
class_name LocalAgentsDownloadController

@export var output_log: RichTextLabel

const FETCH_SCRIPT := "res://addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh"

func _ready() -> void:
    if output_log:
        output_log.clear()
        output_log.append_text(_instructions())

func download_all() -> void:
    _log_action("./scripts/fetch_dependencies.sh")

func download_models_only() -> void:
    _log_action("./scripts/fetch_dependencies.sh --skip-voices")

func download_voices_only() -> void:
    _log_action("./scripts/fetch_dependencies.sh --skip-models")

func clean_downloads() -> void:
    _log_action("./scripts/fetch_dependencies.sh --clean")

func _log_action(command: String) -> void:
    if output_log:
        output_log.clear()
        output_log.append_text(_instructions())
        output_log.append_text("\nRun: %s\n" % command)

func _instructions() -> String:
    return "Run the fetch script from a terminal:\n" +
        "cd addons/local_agents/gdextensions/localagents\n" +
        "./scripts/fetch_dependencies.sh\n"
*** End
