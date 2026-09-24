@tool
class_name LAEventViewRegistry
extends Resource

## One record per observed kind, keyed by the kind's name: the one declaration of how it is drawn and fed.

@export var views: Dictionary[StringName, LAEventViewRecord] = {}
