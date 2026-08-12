extends SceneTree

func _cmp(label: String, a, b) -> void:
	var sa: Array = []
	var sb: Array = []
	for x in a: sa.append(str(x))
	for x in b: sb.append(str(x))
	sa.sort(); sb.sort()
	if sa == sb:
		print("OK    %s (%d)" % [label, sa.size()])
		return
	var only_old: Array = []
	var only_new: Array = []
	for x in sa: if not sb.has(x): only_old.append(x)
	for x in sb: if not sa.has(x): only_new.append(x)
	print("DIFF  %s  only-in-existing=%s  only-in-Channels=%s" % [label, only_old, only_new])

func _init() -> void:
	var G: GDScript = load("res://addons/local_agents/sim/material/MaterialSphereGPU3D.gd")
	var H: GDScript = load("res://addons/local_agents/sim/material/HeatCapacity.gd")
	var B: GDScript = load("res://addons/local_agents/sim/material/reactions/ReactionBalance.gd")
	_cmp("PAIR", G.PAIR_CHANNELS, LAChannels.pair_channels())
	_cmp("SINGLE", G.SINGLE_CHANNELS, LAChannels.single_channels())
	_cmp("SITUATIONAL", G.SITUATIONAL_CHANNELS, LAChannels.situational_channels())
	_cmp("SLOW", G.SLOW_CHANNELS, LAChannels.slow_channels())
	_cmp("LITHOSPHERE", B.LITHOSPHERE_CHANNELS, LAChannels.lithosphere_channels())
	_cmp("INVENTORY(keys)", B.INVENTORY_CHANNELS.keys(), LAChannels.inventory_channels().keys())
	_cmp("SLOT_SUBSTANCE(keys)", B.SLOT_SUBSTANCE.keys(), LAChannels.slot_substance().keys())
	for g in ["MATRIX", "SILICATE", "WATER_LIQUID", "WATER_SOLID", "WATER_VAPOUR", "ORGANIC", "CARBONATE", "SILICA"]:
		_cmp("HEAT:" + g, H.get(g), LAChannels.heat_group(g))
	quit()
