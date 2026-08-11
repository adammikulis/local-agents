@tool
extends Resource
class_name LocalAgentDemoEntry

## One rung of the demo ladder, as data.
##
## An entry is a Resource in `examples/demos/`, following the `creatures/species/*.json` precedent: drop
## a file in the directory and it appears in the launcher. Nothing to edit in code.
##
## `scene_path` is a plain path string, deliberately not a PackedScene. A PackedScene reference is a
## real dependency, so loading the entries to paint a menu would also load every demo scene and its
## whole script graph on the screen that is the addon's front door.
##
## Drift is caught by scripts/check_demo_catalog.sh, which fails the build when an entry points at a
## scene that does not exist.
##
## (Explicit types only. The project rule bans ':=' inferred typing.)

## Position on the ladder, low to high. The launcher sorts on this and numbers the rows from it, so
## the list always reads simplest-first. Entries are spaced by ten in-tree, leaving room to insert a
## new rung without renumbering its neighbours. Two entries sharing an order is a catalogue error
## (scripts/check_demo_catalog.sh fails on it) because the resulting row order would be arbitrary.
@export_range(0, 999, 1) var order: int = 0

## Row heading, e.g. "Two agents converse". Do not number it. The launcher prefixes the position
## itself, so a hand-typed "3." would go stale the moment a rung is inserted above it.
@export var title: String = ""

## One or two sentences: what this demo shows that the rung above it did not.
@export_multiline var description: String = ""

## The scene the Open button runs. A path, loaded on click rather than when the menu opens, and the
## note above says why. check_demo_catalog.sh fails the build if it does not resolve.
@export_file("*.tscn") var scene_path: String = ""

## Set when the demo can do nothing at all without a GGUF model installed. The launcher greys the row
## out and prints LocalAgentStatus's fix sentence for whatever is actually missing.
##
## Leave this false for a demo that degrades honestly, with canned conversation lines, manual
## buttons that fire the same actions the model would, or a setup checklist. Those are worth
## opening precisely when there is no model, and gating them would hide the demo that explains how
## to fix the problem.
@export var requires_model: bool = false

## Set when the demo needs the godot_voxel GDExtension (addons/zylann.voxel/). In practice that means
## any demo that builds a cubed-sphere planet. The launcher greys the row out when `ClassDB` has no
## VoxelLodTerrain.
@export var requires_voxel_backend: bool = false
