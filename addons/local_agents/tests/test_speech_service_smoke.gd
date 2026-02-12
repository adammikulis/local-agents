@tool
extends RefCounted

const SpeechService := preload("res://addons/local_agents/runtime/audio/SpeechService.gd")
const RuntimePaths := preload("res://addons/local_agents/runtime/RuntimePaths.gd")

func run_test(_tree: SceneTree) -> bool:
    var service = SpeechService.new()
    var ok := true

    var synth_result: Dictionary = service.synthesize({
        "text": "hello",
        "voice_path": "",
        "output_path": "",
    })
    ok = ok and not bool(synth_result.get("ok", false))
    ok = ok and String(synth_result.get("error", "")) in ["missing_voice_path", "runtime_missing", "runtime_directory_missing"]

    var transcribe_result: Dictionary = service.transcribe({
        "input_path": "",
        "model_path": "",
    })
    ok = ok and not bool(transcribe_result.get("ok", false))
    ok = ok and String(transcribe_result.get("error", "")) in ["missing_input_path", "runtime_missing"]

    var report: Dictionary = RuntimePaths.voice_asset_report("definitely-missing-voice-id")
    ok = ok and not bool(report.get("ok", false))
    ok = ok and String(report.get("error", "")) == "voice_missing"

    if ok:
        print("Local Agents speech smoke test passed")
    else:
        push_error("Speech smoke assertions failed")
    return ok
