class_name LAFamilyTreePanel
extends CanvasLayer

## FAMILY-TREE INSPECTOR — a pure READER over the permanent kinship graph (LAKinshipGraph). When a creature is
## selected and the "Family tree" debug view is on, it walks that graph from the selected creature — ancestors
## up (parents → grandparents, capped) and descendants down (offspring, capped), with mate(s) alongside — and
## draws a simple 2D node-link diagram: boxes = individuals (species + short id), lines = parent/child, a
## distinct dashed style = mate bonds, the selected creature highlighted as the root. Alive kin are tinted by
## species; dead / carcass / freed kin are greyed so a lineage stays legible after relatives die. Rebuilds ONLY
## on select (not per frame). Click a box to re-root the tree on that individual. (Explicit types — no ':=' .)

const MAX_GEN_UP: int = 4          # ancestor generations walked above the root
const MAX_GEN_DOWN: int = 4        # descendant generations walked below the root
const MAX_NODES: int = 48          # hard cap so a huge component can't blow up the layout / draw cost

const BOX_W: float = 118.0
const BOX_H: float = 34.0
const H_GAP: float = 16.0          # min horizontal gap between boxes in a row
const V_GAP: float = 62.0          # vertical distance between generation rows
const PANEL_W: float = 440.0

var _kinship: LAKinshipGraph = null
var _enabled: bool = false
var _root_cid: int = 0             # instance id of the selected creature the tree is rooted on (0 = none)

var _panel: PanelContainer = null
var _canvas: Control = null

# Built layout (rebuilt on select): each node is a Dictionary, plus the edge list.
var _nodes: Array = []             # [{cid, species, dead, is_root, level, rect:Rect2}]
var _edges: Array = []             # [{a_cid, b_cid, mate:bool}]
var _index: Dictionary = {}        # cid -> index into _nodes

# Species tints (alive). Anything unlisted falls back to a neutral blue-grey.
const SPECIES_COLORS: Dictionary = {
	"rabbit": Color(0.72, 0.66, 0.55),
	"fox": Color(0.92, 0.45, 0.18),
	"bird": Color(0.35, 0.70, 0.95),
	"vulture": Color(0.55, 0.40, 0.55),
	"villager": Color(0.85, 0.78, 0.40),
	"fish": Color(0.35, 0.80, 0.80),
}
const DEAD_COLOR: Color = Color(0.34, 0.35, 0.38)
const ROOT_BORDER: Color = Color(1.0, 0.92, 0.20)
const PARENT_LINE: Color = Color(0.80, 0.84, 0.90, 0.85)
const MATE_LINE: Color = Color(0.95, 0.45, 0.75, 0.95)


func _ready() -> void:
	layer = 51
	_panel = PanelContainer.new()
	# Sit in the open centre-left area: clear of the left DEBUG menu (~182 px wide) and the right creature
	# inspector HUD, which is on-screen precisely when a creature is selected (i.e. whenever this panel draws).
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(196.0, 90.0)
	_panel.custom_minimum_size = Vector2(PANEL_W, 300.0)
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.10, 0.88)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(6.0)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)

	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(PANEL_W - 12.0, 288.0)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_draw_tree)
	_canvas.gui_input.connect(_on_canvas_input)
	_panel.add_child(_canvas)
	_panel.visible = false


func set_kinship(kin: LAKinshipGraph) -> void:
	_kinship = kin


## Toggle the whole inspector (the "Family tree" debug checkbox). When turned on it rebuilds against whatever
## is currently selected; when off it hides.
func set_enabled(on: bool) -> void:
	_enabled = on
	if _panel != null:
		_panel.visible = on
	if on:
		_rebuild()


## Called on selection change. `node` is the selected creature (or null). Re-roots the tree; cheap no-op walk
## when disabled or when the selection isn't a creature.
func set_root(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.is_in_group("creature"):
		_root_cid = int(node.get_instance_id())
	else:
		_root_cid = 0
	_rebuild()


# --- graph walk + layout (on select only) ------------------------------------------------------------------

func _rebuild() -> void:
	_nodes = []
	_edges = []
	_index = {}
	if not _enabled or _kinship == null or _root_cid == 0:
		if _canvas != null:
			_canvas.queue_redraw()
		return

	# BFS out from the root: parents raise the level, children lower it, mates share their partner's level.
	# `levels` keys every reachable cid → its generation row relative to the root (0). A visited set + the node
	# cap keep the walk bounded even in a large connected component.
	var levels: Dictionary = {}
	levels[_root_cid] = 0
	_add_node(_root_cid, 0, true)
	var queue: Array = [_root_cid]
	while not queue.is_empty() and _nodes.size() < MAX_NODES:
		var cid: int = int(queue.pop_front())
		var lvl: int = int(levels[cid])
		# Mate(s): same generation row, drawn beside the individual.
		for m in _kinship.mates_of(cid):
			var mi: int = int(m)
			_record_edge(cid, mi, true)
			if not levels.has(mi) and _nodes.size() < MAX_NODES:
				levels[mi] = lvl
				_add_node(mi, lvl, false)
				queue.append(mi)
		# Parents: one row up (ancestors), capped.
		if lvl > -MAX_GEN_UP:
			for p in _kinship.parents_of(cid):
				var pi: int = int(p)
				_record_edge(pi, cid, false)
				if not levels.has(pi) and _nodes.size() < MAX_NODES:
					levels[pi] = lvl - 1
					_add_node(pi, lvl - 1, false)
					queue.append(pi)
		# Children: one row down (descendants), capped.
		if lvl < MAX_GEN_DOWN:
			for c in _kinship.children_of(cid):
				var ci: int = int(c)
				_record_edge(cid, ci, false)
				if not levels.has(ci) and _nodes.size() < MAX_NODES:
					levels[ci] = lvl + 1
					_add_node(ci, lvl + 1, false)
					queue.append(ci)

	_layout()
	if _canvas != null:
		_canvas.queue_redraw()


func _add_node(cid: int, level: int, is_root: bool) -> void:
	if _index.has(cid):
		return
	var species: String = "?"
	var dead: bool = true
	var obj: Object = instance_from_id(cid)
	if obj != null and is_instance_valid(obj) and obj is Node:
		var n: Node = obj as Node
		species = String(n.get("species")) if "species" in n else "?"
		dead = bool(n.get("_dying")) or bool(n.get("_dead")) or bool(n.get("_carcass"))
	_index[cid] = _nodes.size()
	_nodes.append({"cid": cid, "species": species, "dead": dead, "is_root": is_root, "level": level, "rect": Rect2()})


func _record_edge(a_cid: int, b_cid: int, mate: bool) -> void:
	for e in _edges:
		if bool(e["mate"]) == mate and \
				((int(e["a_cid"]) == a_cid and int(e["b_cid"]) == b_cid) or (int(e["a_cid"]) == b_cid and int(e["b_cid"]) == a_cid)):
			return
	_edges.append({"a_cid": a_cid, "b_cid": b_cid, "mate": mate})


# Assign each node a rect: rows by generation level (root row centred), spread horizontally within a row. Sizes
# the canvas to fit so the panel grows with the tree (bounded by the node cap).
func _layout() -> void:
	if _nodes.is_empty():
		return
	var by_level: Dictionary = {}   # level -> Array of node indices
	var min_lvl: int = 0
	var max_lvl: int = 0
	for i in range(_nodes.size()):
		var lvl: int = int(_nodes[i]["level"])
		min_lvl = mini(min_lvl, lvl)
		max_lvl = maxi(max_lvl, lvl)
		if not by_level.has(lvl):
			by_level[lvl] = []
		(by_level[lvl] as Array).append(i)

	var rows: int = max_lvl - min_lvl + 1
	var widest: int = 1
	for lvl in by_level.keys():
		widest = maxi(widest, (by_level[lvl] as Array).size())
	var content_w: float = maxf(PANEL_W - 12.0, float(widest) * (BOX_W + H_GAP))
	var top_margin: float = 26.0     # room for the title line
	var content_h: float = top_margin + float(rows) * V_GAP + 8.0

	for lvl in by_level.keys():
		var row: Array = by_level[lvl]
		var count: int = row.size()
		var total_w: float = float(count) * BOX_W + float(count - 1) * H_GAP
		var start_x: float = (content_w - total_w) * 0.5
		var y: float = top_margin + float(int(lvl) - min_lvl) * V_GAP
		for j in range(count):
			var idx: int = int(row[j])
			var x: float = start_x + float(j) * (BOX_W + H_GAP)
			_nodes[idx]["rect"] = Rect2(x, y, BOX_W, BOX_H)

	if _canvas != null:
		_canvas.custom_minimum_size = Vector2(content_w, content_h)


# --- drawing -----------------------------------------------------------------------------------------------

func _draw_tree() -> void:
	if _canvas == null:
		return
	var font: Font = ThemeDB.fallback_font
	if _root_cid == 0 or _nodes.is_empty():
		_canvas.draw_string(font, Vector2(8.0, 20.0), "Family tree — select a creature",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.7, 0.74, 0.82))
		return

	# Title.
	var root_node: Dictionary = _nodes[int(_index[_root_cid])] if _index.has(_root_cid) else {}
	var title: String = "Family tree — %s #%d" % [String(root_node.get("species", "?")), _root_cid % 10000]
	_canvas.draw_string(font, Vector2(8.0, 18.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color(0.82, 0.86, 0.94))

	# Edges first (under the boxes). Parent/child solid, mate dashed + distinct colour.
	for e in _edges:
		if not _index.has(int(e["a_cid"])) or not _index.has(int(e["b_cid"])):
			continue
		var ra: Rect2 = _nodes[int(_index[int(e["a_cid"])])]["rect"]
		var rb: Rect2 = _nodes[int(_index[int(e["b_cid"])])]["rect"]
		var pa: Vector2 = ra.position + ra.size * 0.5
		var pb: Vector2 = rb.position + rb.size * 0.5
		if bool(e["mate"]):
			_draw_dashed(pa, pb, MATE_LINE)
		else:
			_canvas.draw_line(pa, pb, PARENT_LINE, 2.0)

	# Boxes on top.
	for nd in _nodes:
		var rect: Rect2 = nd["rect"]
		var dead: bool = bool(nd["dead"])
		var base: Color = DEAD_COLOR if dead else SPECIES_COLORS.get(String(nd["species"]), Color(0.45, 0.55, 0.68))
		var fill: Color = base.darkened(0.35) if not dead else DEAD_COLOR.darkened(0.15)
		fill.a = 0.95
		_canvas.draw_rect(rect, fill, true)
		# Border: yellow + thick for the selected root, else the (dimmed if dead) species colour.
		var border: Color = ROOT_BORDER if bool(nd["is_root"]) else base
		var bw: float = 3.0 if bool(nd["is_root"]) else 1.5
		_canvas.draw_rect(rect, border, false, bw)
		var label_col: Color = Color(0.55, 0.57, 0.60) if dead else Color(0.96, 0.97, 0.99)
		var line1: String = String(nd["species"])
		if dead:
			line1 += " ✝"
		_canvas.draw_string(ThemeDB.fallback_font, rect.position + Vector2(7.0, 15.0), line1,
			HORIZONTAL_ALIGNMENT_LEFT, BOX_W - 12.0, 12, label_col)
		_canvas.draw_string(ThemeDB.fallback_font, rect.position + Vector2(7.0, 29.0), "#%d" % (int(nd["cid"]) % 10000),
			HORIZONTAL_ALIGNMENT_LEFT, BOX_W - 12.0, 10, label_col.darkened(0.1))


func _draw_dashed(a: Vector2, b: Vector2, col: Color) -> void:
	var dist: float = a.distance_to(b)
	if dist < 0.001:
		return
	var dir: Vector2 = (b - a) / dist
	var seg: float = 6.0
	var t: float = 0.0
	while t < dist:
		var t2: float = minf(t + seg, dist)
		_canvas.draw_line(a + dir * t, a + dir * t2, col, 2.0)
		t += seg * 2.0


# Click a box to re-root the tree on that individual (if it's still alive / selectable).
func _on_canvas_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	for nd in _nodes:
		if (nd["rect"] as Rect2).has_point(mb.position):
			var obj: Object = instance_from_id(int(nd["cid"]))
			if obj != null and is_instance_valid(obj) and obj is Node:
				set_root(obj as Node)
			return
