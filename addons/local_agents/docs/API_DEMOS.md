# API: demo harness and catalogue

Part of the [API reference](API.md).

## Demo harness and catalogue

### LocalAgentDemoHarness

`addons/local_agents/runtime/DemoHarness.gd`, extends `Node`.

The headless run, report and screenshot harness for a demo scene. Drop it under any scene root, point `report_source` at the node
that knows the numbers, and that scene gains the standard command-line contract:

```
godot --headless --path . <scene>.tscn -- --run-frames=120
godot --path . <scene>.tscn -- --shoot=shot.png --shoot-frames=90
```

The report source only answers questions and never reads the command line itself. Every hook below is optional, and with none of
them the report body is `{}`:

- `demo_report() -> Dictionary`. The payload, printed as JSON. This is the normal case.
- `demo_report_json() -> String`. The payload already serialised, for when exact number formatting matters more than JSON
  conventions. It wins when present.
- `demo_exit_code() -> int`. The process exit code, default 0, so a smoke scene can fail.
- `demo_shot_info() -> String`. Extra `key=value` text appended to the `SHOT_SAVED` line.
- `demo_harness_configured(frames: int, shoot: String) -> void`. Called once, right after the command line is parsed, so the scene
  can react to the resolved settings without re-reading argv.

#### Exports, group Headless run
- `run_frames` (int, default `0`, range 0 to 100000, suffix frames). Frames to run before printing the report and quitting. 0 never
  auto-quits. `-- --run-frames=N` overrides it.
- `report_source` (Node, default `null`). Empty uses the parent, so dropping the harness under a scene root works.
- `report_prefix` (String, default `"DEMO"`).
- `report_suffix` (String, default `"_REPORT"`). The default prints `PREFIX_REPORT={...}`. Clear it to print a bare `PREFIX={...}`.

#### Exports, group Screenshot
- `shoot_path` (String, default `""`, `@export_global_file("*.png")`). Empty means no screenshot. Global rather than
  `res://`-scoped, because this is an output path and `res://` is read-only in an exported build. `-- --shoot=<path>` overrides it.
- `shoot_frames` (int, default `90`, range 1 to 100000, suffix frames). `-- --shoot-frames=N` overrides it.

A scene given both flags is photographed, not measured: the screenshot branch is checked first.

#### Exports, group Exit
- `use_app_exit` (bool, default `true`). Route the quit through an `AppExit` autoload when one is registered, otherwise
  `get_tree().quit()`. The node resolves that autoload by name at runtime, so the harness works in projects that do not register it.

#### Methods and constants
```gdscript
func frames_elapsed() -> int
func emit_report() -> void
static func print_complete(code: int) -> void
```

`emit_report()` prints the report line now without quitting, so a host can force a report at any moment. The payload is serialised
with `JSON.stringify(payload, "", false)`, so fields print in the order the source declared them rather than alphabetised. The
parsed argument prefixes are exposed as `ARG_RUN_FRAMES` (`"--run-frames="`), `ARG_SHOOT` (`"--shoot="`) and `ARG_SHOOT_FRAMES`
(`"--shoot-frames="`). This node has no configuration warnings.

`print_complete()` prints `LA_RUN_COMPLETE={"code":N}`, and `COMPLETE_MARKER` holds `"LA_RUN_COMPLETE"`. It is static so a scene
with its own harness can emit the identical marker. That line is the only reliable end-of-run signal: a watchdog matching
report-shaped lines instead will match a scene's periodic progress lines and kill healthy runs.

### LocalAgentDemoEntry

`addons/local_agents/examples/DemoEntry.gd`, extends `Resource`, `@tool`.

One rung of the demo ladder, as data. Drop a `.tres` into `addons/local_agents/examples/demos/` and it appears in the launcher.
There is nothing to edit in code.

- `order` (int, default `0`, range 0 to 999). Position on the ladder, low to high. The launcher sorts on this and numbers the rows
  from it. In-tree entries are spaced by ten, so a new rung can be inserted without renumbering. Two entries sharing an order is a
  catalogue error.
- `title` (String, default `""`). The row heading. Do not number it: the launcher prefixes the position itself.
- `description` (String, default `""`, multiline). One or two sentences on what this demo shows that the rung above it did not.
- `scene_path` (String, default `""`, `@export_file("*.tscn")`). A path, deliberately not a PackedScene, loaded on click rather than
  when the menu opens. A PackedScene reference is a real dependency, so painting a twelve-row menu would load twelve demo scenes
  and their whole script graphs.
- `requires_model` (bool, default `false`). Set it when the demo can do nothing without a GGUF: the launcher greys the row out and
  prints the fix sentence for whatever is missing. Leave it false for a demo that degrades honestly, such as canned conversation
  lines or a setup checklist, since those are worth opening precisely when there is no model.
- `requires_voxel_backend` (bool, default `false`). Set it when the demo needs godot_voxel. The launcher greys the row out when
  `ClassDB` has no `VoxelLodTerrain`.

Drift between an entry and its scene is caught by `scripts/check_demo_catalog.sh`, which fails the build when an entry points at a
scene that does not exist.

### LocalAgentTutorialStep

`addons/local_agents/ui/tutorial/TutorialStep.gd`, extends `Resource`.

One step in a guided tutorial: the instruction text, what on screen it points at, and the condition that advances to the next step.
Pure data, so steps can be authored in the inspector or built in code, and nothing here knows about any particular scene.

`enum TargetKind { NONE, CONTROL, RECT, WORLD }`. NONE is a centred callout with no spotlight, CONTROL resolves `control_path`
relative to the sequencer's target root, RECT spotlights a fixed screen rectangle, WORLD projects a world-space point to screen
through the sequencer's Camera3D. `enum Advance { NEXT_BUTTON, TARGET_PRESSED, PREDICATE, SIGNAL }`: TARGET_PRESSED requires the
target Control to be a BaseButton, PREDICATE polls `advance_predicate` each frame, and SIGNAL awaits `signal_name` on
`signal_source`.

#### Exports
- `text` (String, default `""`, multiline). The instruction body.
- `title` (String, default `""`). Optional bold heading above the body.
- `target_kind` (TargetKind, default `NONE`).
- `control_path` (NodePath, default `NodePath()`). For CONTROL.
- `rect` (Rect2, default `Rect2()`). For RECT.
- `world_point` (Vector3, default `Vector3.ZERO`). For WORLD.
- `target_pad` (float, default `8.0`). Extra pixels of breathing room around the spotlight.
- `advance` (Advance, default `NEXT_BUTTON`).

#### Runtime-only variables
Callables and Signals do not serialise on a Resource, so these are assigned in code and left empty for inspector-authored
NEXT_BUTTON and TARGET_PRESSED steps.

- `advance_predicate` (Callable, default `Callable()`).
- `signal_source` (Object, default `null`).
- `signal_name` (StringName, default `&""`).

#### Static constructors
```gdscript
static func for_control(path: NodePath, body: String, heading: String = "", adv: Advance = Advance.TARGET_PRESSED) -> LocalAgentTutorialStep
static func message(body: String, heading: String = "") -> LocalAgentTutorialStep
static func for_world(point: Vector3, body: String, heading: String = "") -> LocalAgentTutorialStep
static func from_dict(d: Dictionary) -> LocalAgentTutorialStep
```

`from_dict()` builds a step from a loose Dictionary, which is handy for JSON-authored tutorials. The recognised keys mirror the
exports: `text`, `title`, `target_kind`, `control_path`, `rect`, `world_point`, `target_pad`, `advance`. `target_kind` accepts an
int or one of `"none"`, `"control"`, `"rect"`, `"world"`, and `advance` accepts an int or one of `"next"`, `"target"`,
`"target_pressed"`, `"predicate"`, `"signal"`. Anything unrecognised falls back to NONE and NEXT_BUTTON.

---

[Back to the API reference index](API.md)
