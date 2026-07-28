@tool
extends Resource
class_name LocalAgentDemoEntry

## One rung of the demo ladder, as data.
##
## The launcher used to carry a `const DEMOS` array of untyped Dictionaries holding `res://` strings.
## That gave three separate places to keep in step (the array, the README table, docs/USAGE.md) and
## made a renamed scene fail at CLICK time, as a button labelled "Missing", rather than at edit time.
##
## An entry is a Resource in `examples/demos/` instead, following the `creatures/species/*.json`
## precedent: drop a file in the directory and it appears in the launcher. Nothing to edit in code.
##
## `scene_path` is a PATH, deliberately not a PackedScene. A PackedScene reference is a real
## dependency, so loading twelve entries to paint a menu also loaded twelve demo scenes and their
## entire script graphs — measured at ~563 ms of blocking work in _ready() against ~92 us for a path
## check, on the one screen that is the addon's front door.
##
## Drift is caught by scripts/check_demo_catalog.sh instead, which fails the build when an entry
## points at a scene that does not exist. That is strictly better than the PackedScene version, which
## did NOT fail loudly as claimed: a missing scene made the whole .tres fail to load, and the launcher
## logged a warning and silently dropped the row.
##
## (Explicit types only — project rule: no ':=' inferred typing.)

## Position on the ladder, low to high. The launcher sorts on this and numbers the rows from it, so
## the list always reads simplest-first. Entries are spaced by ten in-tree, leaving room to insert a
## new rung without renumbering its neighbours. Two entries sharing an order is a catalogue error
## (scripts/check_demo_catalog.sh fails on it) because the resulting row order would be arbitrary.
@export_range(0, 999, 1) var order: int = 0

## Row heading, e.g. "Two agents converse". Do NOT number it — the launcher prefixes the position
## itself, so a hand-typed "3." would go stale the moment a rung is inserted above it.
@export var title: String = ""

## One or two sentences: what this demo shows that the rung above it did not.
@export_multiline var description: String = ""

## The scene the Open button runs. A path, loaded on click rather than when the menu opens — see the
## note above. check_demo_catalog.sh fails the build if it does not resolve.
@export_file("*.tscn") var scene_path: String = ""

## Set when the demo can do nothing at all without a GGUF model installed. The launcher greys the row
## out and prints LocalAgentStatus's fix sentence for whatever is actually missing.
##
## Leave this FALSE for a demo that degrades honestly — canned conversation lines, manual buttons
## that fire the same actions the model would, a setup checklist. Those are worth opening precisely
## when there is no model, and gating them would hide the demo that explains how to fix the problem.
@export var requires_model: bool = false

## Set when the demo needs the godot_voxel GDExtension (addons/zylann.voxel/) — anything building a
## cubed-sphere planet. The launcher greys the row out when `ClassDB` has no VoxelLodTerrain.
@export var requires_voxel_backend: bool = false
