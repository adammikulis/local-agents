class_name LAVoxelHarness
extends RefCounted


static func _count_meshes(n: Node) -> int:
	var c: int = 0
	if n is MeshInstance3D and (n as MeshInstance3D).visible and (n as MeshInstance3D).mesh != null:
		c += maxi(1, (n as MeshInstance3D).mesh.get_surface_count())
	for ch in n.get_children():
		c += _count_meshes(ch)
	return c


## What the seeded streams have drawn, per domain and per caller. The streams exist whatever life the
## world holds, so this is not the population's line.
static func emit_rng_trace(frame: int) -> void:
	if not LASimRng.trace_enabled:
		return
	var rep: Dictionary = LASimRng.shared().trace_report()
	print("RNG_TRACE={\"frame\":%d,\"draws\":%d,\"domains\":%s,\"tags\":%s}" % [
		frame, int(rep["draws"]), JSON.stringify(LASimRng.domain_trace()), JSON.stringify(rep["tags"])])


# Compact population + mortality trajectory sample, printed periodically through a long run-frames run so the
# population arc (and WHY it moves — which death causes dominate) is visible over time, not just at the end.
# One line the balance harness scrapes: POP_TRACE={frame, per-species counts, plants/trees, temp, deaths-so-far}.
static func emit_population_trace(w, frame: int) -> void:
	if LAAblate.fauna_off():
		return
	var tree: SceneTree = w.get_tree()
	var counts: Dictionary = {}
	for sp in ["rabbit", "fox", "bird", "villager", "vulture", "fish"]:
		counts[sp] = tree.get_node_count_in_group("species_%s" % sp)
	counts["creatures"] = tree.get_node_count_in_group("creature")
	counts["plants"] = tree.get_node_count_in_group("plant")
	counts["trees"] = tree.get_node_count_in_group("tree")
	_emit_in_box(w, tree)
	var deaths: Dictionary = {}
	var snap: Dictionary = LASimReport.snapshot(true)
	var ev = snap.get("events", {})
	if ev is Dictionary:
		for k in ev:
			if String(k).begins_with("death/"):
				deaths[String(k).substr(6)] = ev[k]
	var temp_mean: float = _num(snap, "temp_mean")
	# Storm life-cycle telemetry: charge_peak (should rise then discharge in a sawtooth, not pin at breakdown)
	# and cumulative bolts (their per-window delta shows lightning clustered in storm episodes, not constant).
	var charge_peak: float = _num(snap, "charge_peak")
	var bolts: int = int(_num(snap, "bolts"))
	var rain: float = _num(snap, "vapour_total")
	var clouds: int = int(_num(snap, "cloud_cells"))
	# Sample the temperature creatures ACTUALLY stand in: read the field at living surface actors (trees/plants).
	var surf_sum: float = 0.0
	var surf_max: float = -1.0e9
	var surf_n: int = 0
	var mat = w._material if "_material" in w else null
	if mat != null and mat.has_method("temp_at"):
		var probes: Array = tree.get_nodes_in_group("tree")
		if probes.size() < 8:
			probes = tree.get_nodes_in_group("plant")
		for i in range(mini(probes.size(), 40)):
			var p = probes[i]
			if is_instance_valid(p) and p is Node3D:
				var t: float = float(mat.temp_at((p as Node3D).global_position + Vector3(0.0, 2.0, 0.0)))
				if not is_finite(t):
					continue
				surf_sum += t
				surf_max = maxf(surf_max, t)
				surf_n += 1
	var surf_mean: float = surf_sum / float(surf_n) if surf_n > 0 else 0.0
	var t_eq: float = 0.0
	var t_pole: float = 0.0
	if mat != null and mat.has_method("temp_at") and w._body != null:
		var ctr: Vector3 = w._body.center()
		var axis: Vector3 = LABodySeeds.spin_axis_of("planet")
		var surf_r: float = 250.0
		var trees0: Array = tree.get_nodes_in_group("tree")
		if trees0.size() > 0 and is_instance_valid(trees0[0]) and trees0[0] is Node3D:
			surf_r = ((trees0[0] as Node3D).global_position - ctr).length()
		var eq_dir: Vector3 = axis.cross(Vector3(1, 0, 0)).normalized()
		if eq_dir.length() < 0.1:
			eq_dir = axis.cross(Vector3(0, 0, 1)).normalized()
		t_eq = float(mat.temp_at(ctr + eq_dir * (surf_r + 2.0)))
		t_pole = float(mat.temp_at(ctr + axis * (surf_r + 2.0)))
	# HERBIVORE FEEDING telemetry: for living rabbits, average energy%, gut-fill%, and the grazable groundcover
	# biomass at their feet — so a starvation collapse tells us WHETHER they can find food (biomass≈0 = no food
	# reachable) or are simply outbred/predated (energy low but biomass present). Decisive for the food question.
	var rab_e: float = 0.0
	var rab_g: float = 0.0
	var rab_b: float = 0.0
	var rab_n: int = 0
	if mat != null and mat.has_method("biomass_at"):
		var rabs: Array = tree.get_nodes_in_group("species_rabbit")
		for i in range(mini(rabs.size(), 30)):
			var rb = rabs[i]
			if is_instance_valid(rb) and rb is Node3D:
				rab_e += float(rb.energy) / maxf(float(rb.max_energy), 1.0)
				rab_g += float(rb.gut) / maxf(float(rb.gut_capacity), 1.0)
				var rp: Vector3 = (rb as Node3D).global_position
				var upv: Vector3 = rb.terrain.up_at(rp) if (rb.terrain != null and rb.terrain.has_method("up_at")) else Vector3.UP
				var feet: Vector3 = rp + upv * maxf(float(rb.size), 0.8)
				rab_b += float(mat.biomass_at(feet.x, feet.y, feet.z))
				rab_n += 1
	if rab_n > 0:
		rab_e /= float(rab_n)
		rab_g /= float(rab_n)
		rab_b /= float(rab_n)
	var t_min: float = _num(snap, "temp_min")
	var t_max: float = _num(snap, "temp_max")
	var snow_c: int = int(_num(snap, "snow_cells"))
	var ice_c: int = int(_num(snap, "ice_cells"))
	var sea_ice: int = int(_num(snap, "sea_ice_cells"))
	var cloud_cover: float = _num(snap, "cloud_cover")
	var open_sea_t: float = _num(snap, "open_sea_temp_mean")
	print("POP_TRACE={\"frame\":%d,\"counts\":%s,\"temp_mean\":%.1f,\"surf_mean\":%.1f,\"surf_max\":%.1f,\"t_eq\":%.1f,\"t_pole\":%.1f,\"rab_e\":%.2f,\"rab_gut\":%.2f,\"rab_bio\":%.4f,\"t_min\":%.1f,\"t_max\":%.1f,\"snow\":%d,\"ice\":%d,\"sea_ice\":%d,\"cloud_cover\":%.3f,\"sea_t\":%.1f,\"charge_peak\":%.2f,\"bolts\":%d,\"moisture\":%.0f,\"cloud_cells\":%d,\"deaths\":%s}" % [frame, JSON.stringify(counts), temp_mean, surf_mean, surf_max, t_eq, t_pole, rab_e, rab_g, rab_b, t_min, t_max, snow_c, ice_c, sea_ice, cloud_cover, open_sea_t, charge_peak, bolts, rain, clouds, JSON.stringify(deaths)])


## WHERE THE LIVING THINGS ARE, against where the field steps matter. A body in no cell reads no
## temperature and no food at its feet, so what the substrate does never reaches it.
static func _emit_in_box(w, tree: SceneTree) -> void:
	var mat = w._material if "_material" in w else null
	if mat == null or not mat.has_method("world_to_cell"):
		return
	var inside: int = 0
	var outside: int = 0
	for grp in ["creature", "plant", "tree"]:
		for n in tree.get_nodes_in_group(grp):
			if not (is_instance_valid(n) and n is Node3D):
				continue
			if int(mat.world_to_cell((n as Node3D).global_position)) >= 0:
				inside += 1
			else:
				outside += 1
	print('LIFE_IN_BOX={"in":%d,"out":%d}' % [inside, outside])


## A reading the run never published is NAN, never zero.
static func _num(snap: Dictionary, key: String) -> float:
	var v: Variant = snap.get(key, null)
	return float(v) if v is float or v is int else NAN


static var _measured_vp: RID = RID()
static var _last_cpu_us: int = -1


## The frame's own cost in ms, from the frame after life is placed: the larger of the main thread's CPU
## time over one main-loop iteration and the viewport's GPU time. GPU time is absent where the driver
## writes no timestamps (Metal), and then only the CPU side is measured.
static func gauge_frame_cost(vp: Viewport, spawned: bool) -> void:
	var rid: RID = vp.get_viewport_rid()
	if rid != _measured_vp:
		RenderingServer.viewport_set_measure_render_time(rid, true)
		_measured_vp = rid
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	var now_us: int = LAThreadClock.cpu_usec()
	var last_us: int = _last_cpu_us
	_last_cpu_us = now_us if spawned else -1
	if last_us < 0 or now_us < 0:
		return
	var cost_ms: float = float(now_us - last_us) / 1000.0
	LASimReport.gauge("frame_cpu_ms", cost_ms)
	var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(rid)
	if gpu_ms > 0.0:
		LASimReport.gauge("frame_gpu_ms", gpu_ms)
		cost_ms = maxf(cost_ms, gpu_ms)
	LASimReport.gauge("frame_cost_ms", cost_ms)


static func build_report(w) -> Dictionary:
	_emit_draw_sources(w)
	LASimReport.gauge("frames", float(w._frame))
	LASimReport.gauge("time_of_day", w._sky_ctrl.time_of_day() if w._sky_ctrl != null else 0.30)
	LASimReport.gauge("fps", Performance.get_monitor(Performance.TIME_FPS))
	LASimReport.gauge("process_ms", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	LASimReport.gauge("physics_ms", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	LASimReport.gauge("nodes", Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	LASimReport.gauge("draw_calls", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	LASimReport.gauge("prims_M", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1.0e6)
	LASimReport.gauge("video_mem_MB", Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1.048576e6)
	var cam: Camera3D = w.get_viewport().get_camera_3d() if w.get_viewport() != null else null
	if cam != null:
		LASimReport.gauge("camera_far", cam.far)   # proof the draw-distance knob bites
	return LASimReport.snapshot()


static func _emit_draw_sources(w) -> void:
	# Draw-call source breakdown (mesh surfaces per actor group), an instancing target, only under LA_PROFILE.
	if OS.has_environment("LA_PROFILE"):
		var parts: PackedStringArray = PackedStringArray()
		for g in ["creature", "fish", "plant", "tree", "rock", "nest", "villager"]:
			var nodes: Array = w.get_tree().get_nodes_in_group(g)
			var m: int = 0
			for nd in nodes:
				m += _count_meshes(nd)
			parts.append("%s:n=%d,surf=%d" % [g, nodes.size(), m])
		print("DRAW_SOURCES={%s}" % ", ".join(parts))


static func sample_night(w) -> void:
	var eco = w._ecology
	if eco == null or not eco.has_method("is_night_at"):
		return
	var live: int = 0
	var dark: int = 0
	var resting: int = 0
	for c in w.get_tree().get_nodes_in_group("creature"):
		if not is_instance_valid(c) or c.get("_dead"):
			continue
		live += 1
		var night: bool = eco.is_night_at(c.global_position)
		if night:
			dark += 1
		if night != bool(c.get("nocturnal")):
			resting += 1
	if live <= 0:
		return
	LASimReport.gauge("night_frac", float(dark) / float(live))
	LASimReport.gauge("resting_frac", float(resting) / float(live))


const UI_DIR: String = "res://addons/local_agents/game/ui/"
const MENU_DIR: String = "res://addons/local_agents/game/menu/"


## Every presentation node in the tree, by path and by what made it one; a run with no --ui must have
## none. Prints TREE_PRESENTATION={"scanned":N,"nodes":[...]} for check_presentation_absent.sh.
static func emit_presentation_census(root: Node) -> int:
	var found: PackedStringArray = PackedStringArray()
	var scanned: int = _scan_presentation(root, found)
	print("TREE_PRESENTATION={\"scanned\":%d,\"nodes\":%s}" % [scanned, JSON.stringify(found)])
	return found.size()


static func _scan_presentation(n: Node, found: PackedStringArray) -> int:
	var seen: int = 1
	var why: String = ""
	if n is Control or n is CanvasLayer:
		why = n.get_class()
	else:
		var scr: Script = n.get_script() as Script
		if scr != null and (scr.resource_path.begins_with(UI_DIR) or scr.resource_path.begins_with(MENU_DIR)):
			why = scr.resource_path
	if why != "":
		found.append("%s|%s" % [String(n.get_path()), why])
	for ch in n.get_children():
		seen += _scan_presentation(ch, found)
	return seen


## Appended to SHOT_SAVED: the eye's place, aim, vertical field of view and horizon dip, the built ground
## down the aim, whether that ground is drawn, whether the eye stands in the slice box, the field glyphs in
## the frame, what the 3-D half of the picture holds, and the pixels the HUD covers.
static func shot_info(w) -> String:
	var cam: Camera3D = w._camera
	if cam == null:
		return "cam=absent ground_meshed=false cam_in_slice=false field_arrows=0"
	var up: Vector3 = w._body.up_at(cam.global_position)
	var fwd: Vector3 = -cam.global_transform.basis.z
	var mode: String = "fly" if cam.is_fly() else ("solar" if cam.is_solar_view() else "orbit")
	var aim: float = float(cam.aim_distance()) if cam.has_method("aim_distance") else 0.0
	var alt: float = w._sim.terrain().altitude_at(cam.global_position)
	var r_eye: float = cam.global_position.distance_to(w._body.center())
	return ("cam=%s cam_alt_m=%.0f cam_pitch_deg=%.1f cam_fov_deg=%.3f horizon_dip_deg=%.4f "
		+ "ground_ahead_m=%.0f aim_ahead_m=%.0f ground_meshed=%s cam_in_slice=%s field_arrows=%d %s "
		+ "hud_px=%s") % [
		mode, alt, rad_to_deg(asin(clampf(fwd.dot(up), -1.0, 1.0))), cam.fov,
		rad_to_deg(acos(clampf((r_eye - alt) / r_eye, -1.0, 1.0))), _ground_ahead(w, cam, fwd), aim,
		"true" if shot_ready(w) else "false", "true" if _cam_in_slice(w, cam) else "false",
		_arrow_count(w), _scene_stats(w), _hud_px(w)]


## Every HUD panel's rectangle in image pixels, [x, y, w, h], as JSON with no space in it; `absent` with
## no picture to cover.
static func _hud_px(w) -> String:
	var vp: Viewport = w.shot_viewport()
	if vp == null:
		return "absent"
	var size: Vector2 = vp.get_visible_rect().size
	var out: Array = []
	for r in _hud_rects(w, size.x * size.y):
		out.append([roundi(r.position.x), roundi(r.position.y), roundi(r.size.x), roundi(r.size.y)])
	return JSON.stringify(out).replace(" ", "")


## Whether the eye stands inside the slice box the field was laid on. False when there is no slice: a
## world without a box cannot have framed one.
static func _cam_in_slice(w, cam: Camera3D) -> bool:
	var field: Node = w._sim.material_field()
	var box: AABB = LARenderLayer.slice_body_aabb(field, w._body)
	# The box is body-fixed, so the eye is asked about in the FIELD's own frame, not in world space.
	return box.size.length() > 0.0 and box.has_point(field.point_to_field(cam.global_position))


static func _arrow_count(w) -> int:
	var vectors = w._render.field_vectors() if w._render != null else null
	return int(vectors.drawn()) if vectors != null else 0


## What the picture holds, over the scene alone: every sample landing on a HUD panel is dropped.
## Publishes scene_mean scene_var scene_split scene_contrast scene_spread.
const SCENE_SAMPLES: int = 64
## A Control this large is the layout root, not a panel: it covers the scene rather than hiding it.
const HUD_MAX_FRAME_FRAC: float = 0.5

static func _scene_stats(w) -> String:
	var vp: Viewport = w.shot_viewport()
	var tex: ViewportTexture = vp.get_texture() if vp != null else null
	var img: Image = tex.get_image() if tex != null else null
	if img == null or img.get_width() < 4 or img.get_height() < 4:
		return _absent_stats()
	var hud: Array[Rect2] = _hud_rects(w, float(img.get_width()) * float(img.get_height()))
	var means: PackedFloat32Array = PackedFloat32Array()
	var vars: PackedFloat32Array = PackedFloat32Array()
	for j in SCENE_SAMPLES:
		var y: int = img.get_height() * j / SCENE_SAMPLES
		var n: int = 0
		var sum: float = 0.0
		var sq: float = 0.0
		for i in SCENE_SAMPLES:
			var p: Vector2 = Vector2(float(img.get_width() * i / SCENE_SAMPLES), float(y))
			if _in_any(hud, p):
				continue
			var v: float = img.get_pixel(int(p.x), int(p.y)).get_luminance()
			n += 1
			sum += v
			sq += v * v
		if n < SCENE_SAMPLES / 2:
			continue                       # a row the HUD mostly covers is not a row of the scene
		means.append(sum / float(n))
		vars.append(maxf(0.0, sq / float(n) - (sum / float(n)) * (sum / float(n))))
	if means.size() < 4:
		return _absent_stats()
	return _split_stats(means, vars)


static func _absent_stats() -> String:
	return ("scene_mean=-1 scene_var=-1 scene_split=-1 scene_contrast=-1 scene_spread=-1 "
		+ "scene_var_sky=-1 scene_var_ground=-1")


## The shot's own sky/ground split, and what the step across it has to beat.
static func _split_stats(means: PackedFloat32Array, vars: PackedFloat32Array) -> String:
	var rows: int = means.size()
	var mean_all: float = 0.0
	var var_all: float = 0.0
	for i in rows:
		mean_all += means[i]
		var_all += vars[i]
	mean_all /= float(rows)
	var_all /= float(rows)
	# Otsu's split: the row maximising the between-class variance, weighed by each side's share.
	var best: int = 1
	var score: float = -1.0
	var contrast: float = 0.0
	for k in range(1, rows):
		var hi: float = 0.0
		var lo: float = 0.0
		for i in k:
			hi += means[i]
		for i in range(k, rows):
			lo += means[i]
		var d: float = absf(hi / float(k) - lo / float(rows - k))
		var w: float = float(k) * float(rows - k) / float(rows * rows)
		if w * d * d > score:
			score = w * d * d
			contrast = d
			best = k
	var up_m: float = 0.0
	var low_m: float = 0.0
	for i in best:
		up_m += means[i]
	for i in range(best, rows):
		low_m += means[i]
	up_m /= float(best)
	low_m /= float(rows - best)
	# The wobble left over once the split is taken out: what the contrast has to beat.
	var resid: float = 0.0
	for i in rows:
		var d2: float = means[i] - (up_m if i < best else low_m)
		resid += d2 * d2
	# What each side of the split holds ALONG its own rows: sky is smooth across a row, ground is not.
	var v_up: float = 0.0
	var v_low: float = 0.0
	for i in rows:
		if i < best:
			v_up += vars[i]
		else:
			v_low += vars[i]
	return ("scene_mean=%.6f scene_var=%.6f scene_split=%.6f scene_contrast=%.6f scene_spread=%.6f "
		+ "scene_var_sky=%.6f scene_var_ground=%.6f") % [
		mean_all, var_all, float(best) / float(rows), contrast, sqrt(resid / float(rows)),
		v_up / float(best), v_low / float(rows - best)]


## The HUD panels over the frame, in image pixels; a Control covering most of it is the layout root.
static func _hud_rects(root: Node, frame_area: float) -> Array[Rect2]:
	var out: Array[Rect2] = []
	_collect_hud(root, frame_area, out)
	return out


static func _collect_hud(n: Node, frame_area: float, out: Array[Rect2]) -> void:
	var c: Control = n as Control
	if c != null and c.is_visible_in_tree():
		var r: Rect2 = c.get_global_rect()
		if r.size.x * r.size.y < HUD_MAX_FRAME_FRAC * frame_area:
			out.append(r)
	for ch in n.get_children():
		_collect_hud(ch, frame_area, out)


static func _in_any(rects: Array[Rect2], p: Vector2) -> bool:
	for r in rects:
		if r.has_point(p):
			return true
	return false


## HOW FAR DOWN THE VIEW AXIS THE GROUND STANDS, in metres: the terrain body's own collider, hit by a ray
## from the eye along its aim. Negative when the camera is aimed at nothing that has been built.
static func _ground_ahead(w, cam: Camera3D, fwd: Vector3) -> float:
	var hit: Dictionary = w._sim.terrain().raycast_terrain(cam.global_position, fwd, cam.far)
	if not bool(hit.get("hit", false)):
		return -1.0
	return cam.global_position.distance_to(hit["position"])


## Stand the eye at one pose of the shot protocol: metres over the framed site's ground, degrees from
## the horizon (negative looks down), degrees around the site from the framing axis.
static func shot_pose(w, alt_m: float, pitch_deg: float, yaw_deg: float) -> void:
	var cam: Camera3D = w._camera
	if cam != null and cam.has_method("place_pose"):
		cam.call("place_pose", alt_m, pitch_deg, yaw_deg)


## THE PICTURE IS WORTH TAKING once the ground under the camera is drawn at least as finely as the camera
## stands above it; before that the shot is of a body that has not arrived at the detail it is seen from.
static func shot_ready(w) -> bool:
	var cam: Camera3D = w._camera
	return cam != null and cam.has_method("ground_resolved") and cam.ground_resolved()
