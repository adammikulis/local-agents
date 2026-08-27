extends SceneTree

## The controls enumerate the process table. Every record LAProcessSet declares gets exactly one box in
## LAProcessSetPanel, and every box is a record — so adding a record to the table adds a control, and a
## control that answers to no record cannot exist.

var _fail: int = 0


func _say(msg: String) -> void:
	printerr(msg)
	_fail += 1


func _boxes_of(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is CheckBox:
			out.append(child)
		_boxes_of(child, out)


func _init() -> void:
	var settings: LAGameSettings = LAGameSettings.new()
	var panel: LAProcessSetPanel = LAProcessSetPanel.new()
	panel.build(settings, false)

	var boxes: Array = []
	_boxes_of(panel, boxes)
	var records: Array = LAProcessSet.records()
	if boxes.size() != records.size():
		_say("The panel drew %d boxes for %d process records." % [boxes.size(), records.size()])

	# Every record has a box, and the box is one the panel actually put in the tree.
	var texts: Dictionary = {}
	for b in boxes:
		texts[String((b as CheckBox).text)] = b
	for rec: Dictionary in records:
		var want: String = "%s (%s)" % [String(rec["label"]), String(rec["kind"])]
		if not texts.has(want):
			_say("Process record \"%s\" has no control." % LAProcessSet.record_id(rec))
		else:
			texts.erase(want)
	for leftover in texts:
		_say("The panel drew a control \"%s\" that answers to no process record." % leftover)

	# A rung selection is the set of records at or below it — the same list the boxes would carry.
	for r: Dictionary in LAProcessSet.rungs():
		settings.process_rung = int(r["rung"])
		settings.process_records = PackedStringArray()
		panel.refresh()
		var want_ids: PackedStringArray = LAProcessSet.records_upto(int(r["rung"]))
		var got: PackedStringArray = panel.selection()
		if got.size() != want_ids.size():
			_say("Rung \"%s\" selects %d records; its ladder position holds %d."
				% [r["name"], got.size(), want_ids.size()])

	var rung_buttons: int = 0
	for child in panel.get_children():
		if child is HBoxContainer:
			rung_buttons = (child as HBoxContainer).get_child_count()
	# One button per rung, plus Custom.
	if rung_buttons != LAProcessSet.rungs().size() + 1:
		_say("The panel offers %d rung buttons for %d rungs and a custom mode."
			% [rung_buttons, LAProcessSet.rungs().size()])

	panel.free()
	print('PROCESS_UI={"records":%d,"boxes":%d,"rung_buttons":%d,"failures":%d}'
		% [records.size(), boxes.size(), rung_buttons, _fail])
	quit(1 if _fail > 0 else 0)
