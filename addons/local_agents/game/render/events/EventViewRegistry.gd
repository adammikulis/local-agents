@tool
class_name LAEventViewRegistry
extends Resource

## One record per observed kind: the LAEventView scene that draws it.

@export var views: Dictionary[StringName, PackedScene] = {}
