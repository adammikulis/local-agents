class_name LAEventDetector
extends RefCounted


func detect(_prev: Dictionary, _cur: Dictionary, _dt: float) -> Array:
	return []


func phenomenon() -> String:
	return "unknown"


func signal_live(_cur: Dictionary) -> bool:
	return true
