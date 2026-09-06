class_name LAMaterialSphereGPU3D
extends RefCounted


## Views of LAChannels, the one declaration of what a channel is.
static func channels() -> PackedStringArray: return LAChannels.channels()
const SEED_PRODUCTS: PackedStringArray = ["pressure", "p_fluid"]


# Dispatch order is a data dependency chain: each pass reads what the one above it published.
const PASS_SCRIPTS: PackedStringArray = [
	"res://addons/local_agents/sim/material/sphere_passes/InjectPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/GravityPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/PressurePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/FluxPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReactionsPass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/ReducePass.gd",
	"res://addons/local_agents/sim/material/sphere_passes/MeshExtractPass.gd"]

static func available() -> bool:
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

var _rd: RenderingDevice = null
## The native driver: it sequences the passes, issues every compute list and does the drain's readback.
var _driver: LAFieldDriver = null
## One buffer every channel this drain reads is copied into on the device, so the CPU waits once.
var _staging: RID = RID()
var _staging_slots: int = 0
var _bnd_rids: Array = []
var _inject = null                  # the InjectPass this world runs, or null where it has none
var _field = null
var _grid: RefCounted = null
var _cc: int = 0
var _ng: int = 0                    # ghost tail cells appended past _cc; 0 = every wall shut
var _face_count: int = 0            # faces over interior plus ghost tail: LAVoxelGrid.neighbours
var _bnd_keys: PackedStringArray = PackedStringArray()   # per-step boundary books, cleared before each step
var _step_index: int = 0            # monotonic field-step counter, published to kernels as ctx["step_index"]
var _seed_totals: Dictionary = {}   # per channel: the total the last whole-mirror seed declared
var _groups: int = 0
var _bufs: Dictionary = {}          # channel/buffer name → its one RID
var _passes: Array = []
var _pass_names: PackedStringArray = []   # parallel to _passes — short label per pass, for GPU per-pass timing
var _ctx: Dictionary = {}
var _moving: bool = false           # a pass in this world writes matter or energy
var _buf_owner: Dictionary = {}     # _bufs key -> what claimed it, so a collision can name both claimants
var _pass_results: Dictionary = {}  # merged _drain() readings of the last drained step
var _pending: bool = false          # a step() submit is in flight, not yet synced/read
var _mirrors: LAFieldMirrors = null  # the field's own native mirrors — the drain lands its channels there
var _slow_gate: int = 0             # cadence counter for the slow (ledger/baker) channel readback set

const CHANNEL_HOLD_DRAINS: int = 20     # stay hot ~20 drains past the last request so intermittent queries don't thrash
var _channel_hold: Dictionary = {}      # channel name -> drain index it stays hot through
var _drain_count: int = 0               # monotonic drain counter the holds are measured against
var _probe_want: PackedStringArray = PackedStringArray()
var _probe: Dictionary = {}
# Re-uploaded only when a CPU writer marks them, never per step.
var _solid_dirty: bool = true
var _water_dirty: bool = true
var _h_dirty: bool = true

# Slow channels are read back only every Nth drain: their CPU consumers are coarse-cadence ledgers and
# bakers, not every-frame world queries. Between reads the mirror keeps its prior value, and `live()`
# says which of the two it is.
const SLOW_READBACK_EVERY: int = 4

# BETWEEN-PASS PROBE, armed per step by LAFieldPassAttribution3D and left invalid otherwise. When valid,
# step() runs the checkpointed path below instead of the normal one-submit path. Nothing on the per-frame
# path reads this.
var _step_probe: Callable = Callable()


func setup(field) -> void:
	_field = field
	_grid = field._grid
	_cc = field._cell_count
	# Ghost tail cells the boundary provider appended to the grid before activation; 0 = every wall shut.
	_ng = int(_grid.ghost_rows)
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("LAMaterialSphereGPU3D: no RenderingDevice")
		return
	_driver = LAFieldDriver.new()
	_driver.set_device(_rd)
	_mirrors = field._mirrors
	_mirrors.set_device(_rd)
	_groups = int(ceil(float(_cc) / 64.0))
	var tc: int = _cc + _ng

	for name in channels():
		_bufs[name] = _new_f(tc)
		_buf_owner[name] = "LAChannels.rows()"
	for name in LAChannels.derived_buffers():
		_bufs[name] = _new_f(tc)
		_buf_owner[name] = "LAChannels.derived_buffers()"
	# GRID GEOMETRY. The face list, whose adjacency is the grid's own (scripts/check_neighbour_slots.sh
	# holds the one definition), already carrying any ghost rows the boundary provider appended,
	var nbr_bytes: PackedByteArray = _grid.neighbours.to_byte_array()
	_bufs["nbr"] = _rd.storage_buffer_create(nbr_bytes.size(), nbr_bytes)
	_face_count = _grid.neighbours.size()
	var off_bytes: PackedByteArray = _grid.slot_off.to_byte_array()
	_bufs["slot_off"] = _rd.storage_buffer_create(off_bytes.size(), off_bytes)
	var par_bytes: PackedByteArray = _grid.partners.to_byte_array()
	_bufs["face_partner"] = _rd.storage_buffer_create(par_bytes.size(), par_bytes)
	# The boundary redirect: per face, a wrap partner or a ghost tail cell; -1 keeps the face shut.
	var gh: PackedInt32Array = PackedInt32Array()
	gh.resize(_face_count)
	gh.fill(-1)
	var gh_bytes: PackedByteArray = gh.to_byte_array()
	_bufs["ghost"] = _rd.storage_buffer_create(gh_bytes.size(), gh_bytes)
	var pos_b: PackedByteArray = _grid.centres.to_byte_array()
	_bufs["pos"] = _rd.storage_buffer_create(pos_b.size(), pos_b)
	# The SOLVED gravity, flat cell*3, m/s^2. GravityPass writes it, every kernel that asks which way is
	# down reads it, and nothing anywhere holds a gravity constant.
	_bufs["gravity"] = _new_f(tc * 3)
	# kernels3d/cellvol.glsli, binding 94: metres of edge per cell, the one geometry the kernels read.
	var edge_bytes: PackedByteArray = _grid.cell_edges().to_byte_array()
	_bufs["cell_edge"] = _rd.storage_buffer_create(edge_bytes.size(), edge_bytes)
	var gd: PackedFloat32Array = field._ground_d.duplicate()   # flux.glsl binding 99: ground depth below the centre, m
	gd.resize(tc)
	_bufs["ground_d"] = _rd.storage_buffer_create(gd.to_byte_array().size(), gd.to_byte_array())

	_upload_mirror("e_j_m3")
	_upload_mirror("e_lith_j_m3")
	seed_field("o2", field._seal)
	seed_field("co2", field._seal)   # the atmosphere's carbon — finite, at Earth's mole fraction
	seed_field("n2", field._seal)    # the atmosphere's nitrogen — finite, at Earth's mole fraction
	# The Hadean minor gases: volcanic H2/CO/SO2/H2S, abiotic CH4, at their cited mole fractions.
	for gas in ["h2", "co", "so2", "h2s", "ch4"]:
		seed_field(String(gas), field._seal)
	_upload_mirror("h2o")            # the ocean basin
	_upload_mirror("h2o_pore")       # the primed water table
	LAFieldCellMass3D.upload_solid(_rd, _bufs, _field)
	_seed_silicate()
	_seed_regolith()                    # aquifer permeability mask + grain-size field (static)

	# Cell height in metres for the table's flux-derived rates; the grid is SI. Set before ReactionsPass
	# bakes the table.
	LAReactionDefs.cell_size_m = float(_grid.cell_size)

	for key in _bufs:
		if not _buf_owner.has(key):
			_buf_owner[key] = "the driver"
	# The passes THIS WORLD runs: LAProcessSet resolved the rung before the driver was built, and a pass
	# outside it is never loaded, so nothing it declares is ever allocated.
	for path in LAProcessSet.pass_paths(PASS_SCRIPTS):
		var scr: GDScript = load(path)
		if scr == null:
			push_warning("sphere pass missing: " + path)
			continue
		var p: RefCounted = scr.new()
		if p.has_method("setup"):
			p.ghost_count = _ng
			p.grid_dims = Vector3i(_grid.nx, _grid.ny, _grid.nz)
			p.face_count = _face_count
			p.grid_origin = _grid.origin
			p.grid_cell_size = _grid.cell_size
			_passes.append(p)
			_pass_names.append(path.get_file().get_basename())   # e.g. "FluxPass" — timestamp label
	# A pass declares the buffers it needs and the DRIVER allocates them, so they are driver-owned and can be
	# read back. Every declaration lands before any _setup, so a pass may bind another pass's buffer.
	for i in _passes.size():
		_allocate_declared(_passes[i], _pass_names[i])
		_moving = _moving or _passes[i].get("MOVES_STATE") == true
		if _pass_names[i] == "InjectPass":
			_inject = _passes[i]
	_moving = _moving or LAProcessSet.has_record("derive", "lithify")
	for p2 in _passes:
		p2.setup(_rd, _bufs, _cc)
	# The boundary books are per-step rates: cleared before every step, summed by their reduce rows after.
	for key in _bufs:
		if String(key).begins_with("bnd_"):
			_bnd_keys.append(String(key))
			_bnd_rids.append(_bufs[key])
	# Every name a drain can ask for is a channel or a derived buffer, so this many slots cannot overflow.
	_staging_slots = channels().size() + LAChannels.derived_buffers().size()
	_staging = _rd.storage_buffer_create(_staging_slots * _cc * 4)


## Allocate one pass's declared buffers. A name already in `_bufs` is a collision, not an overwrite: the
## first claimant keeps its RID and both claimants are named.
func _allocate_declared(p: RefCounted, label: String) -> void:
	var want: Dictionary = p._buffers(_cc)
	for key in want:
		var name: String = String(key)
		if _bufs.has(name):
			push_error("%s declares buffer \"%s\", which %s already allocated." % [
				label, name, _buf_owner[name]])
			continue
		var spec: Variant = want[key]
		var n: int = int(spec["n"]) if spec is Dictionary else int(spec)
		var indirect: bool = spec is Dictionary and bool(spec.get("indirect", false))
		# A per-cell buffer a kernel indexes by ghost tail cells declares {"ghosts": true}.
		if spec is Dictionary and bool(spec.get("ghosts", false)):
			n += _ng
		# A per-FACE buffer declares {"faces": true}: the grid's face list is its length.
		if spec is Dictionary and bool(spec.get("faces", false)):
			n = _face_count
		if n <= 0:
			push_error("%s declares buffer \"%s\" of %d elements." % [label, name, n])
			continue
		_bufs[name] = _rd.storage_buffer_create(n * 4, _zeros(n),
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if indirect else 0)
		_buf_owner[name] = label


func begin_frame() -> void:
	if _rd == null:
		return
	# Drain the previous frame's in-flight step FIRST: sync it (usually already done — the GPU ran it during the
	# inter-frame CPU work) and land its channels in the mirrors. Must happen before the uploads below,
	# which write the same live buffers the step wrote. This is the CPU↔GPU overlap that hides the field step cost.
	_drain_pending()
	# The only CPU writer of _h is injection (meteors / lava / geotherm), which marks it dirty.
	if _h_dirty:
		_upload_mirror("e_j_m3")
		_h_dirty = false
	# water is only CPU-modified by injection (add_water / lakes seed), never per-step; after the readback the CPU
	# copy already equals the GPU's evolved water, so re-uploading it every step is redundant. Gate it on a dirty
	# flag the injectors set.
	if _water_dirty:
		_upload_mirror("h2o")
		_water_dirty = false
	# solid + static masks change only on an SDF edit (volcano stamp, terrain edit) — NOT per step. The solid upload
	# rebuilt + uploaded BOTH full-grid buffers every frame; gate it so it only fires when the CPU mask changed.
	if _solid_dirty:
		LAFieldCellMass3D.upload_solid(_rd, _bufs, _field)
		_solid_dirty = false
	_ctx["dt"] = LAMaterialFieldSphereStep3D.real_seconds_per_step()   # simulated seconds, not the cadence
	_ctx["cell_size"] = _grid.cell_size
	_ctx["cell_size_min"] = _grid.cell_size * pow(0.5, float(_grid.max_level))
	# The SOLVED gravity, for the handful of scalar laws a pass evaluates once. A per-cell law reads the
	# g field itself; nothing anywhere reads a gravity constant, because there is not one.
	_ctx["g_m_s2"] = _field._gravity.mean_g() if _field._gravity != null else 0.0
	_ctx["phi_datum"] = _field._gravity.phi_datum() if _field._gravity != null else 0.0
	# March bound: a column cannot be longer than the box.
	_ctx["depth"] = _grid.max_span()
	_ctx["centre"] = _field.centre()     # the body centre — the spin axis passes through it
	_ctx["spin"] = LAFieldGeometry.spin_axis(_field)
	# Rate as well as axis: seeded angular momentum over measured inertia. Zero while unmeasured,
	# which is no rotating frame rather than a guessed one.
	_ctx["spin_rate_rad_s"] = LAFieldGeometry.spin_rate(_field)

## World-space vector toward the sun; its LENGTH is the IRRADIANCE in W/m^2, so the beam a cell sees is
## that magnitude and no kernel multiplies by a solar constant. Absent = no sun, which is dark, not a
## default direction: an axis chosen here would decide where noon is.
func set_sun_flux(v: Vector3, xuv_w_m2: float) -> void:
	_ctx["sun_dir"] = v
	_ctx["xuv_w_m2"] = xuv_w_m2 if is_finite(xuv_w_m2) else 0.0


## Radius of the sea shell from the body centre, metres — the datum the derived `alt` is measured from.
## Absent or zero = the body carries no shell, which is no altitude, not an altitude of zero.
func set_crust_radius(m: float) -> void:
	_ctx["crust_radius"] = m


## Whether anything can write matter or energy this step: a writer pass, or a CPU mirror marked dirty.
func state_moves() -> bool:
	return _moving or _h_dirty or _water_dirty or _solid_dirty


## Mark the CPU enthalpy mirror dirty so the next begin_frame re-uploads it.
func mark_h_dirty() -> void:
	_h_dirty = true


func step() -> void:
	if _rd == null:
		return
	if _pending:
		_rd.sync()
		_pending = false
	_ctx["step_index"] = _step_index
	_ctx["dt_s"] = LAMaterialFieldSphereStep3D.real_seconds_per_step()
	_pre_step()
	_driver.clear_buffers(_bnd_rids, _cc * 4)
	# Deferred sync — drained at the next begin_frame, so the GPU overlaps the CPU frame work.
	_driver.step(_passes, _pass_names, _ctx, _cc, _groups, _step_probe)
	_pending = true
	_step_index += 1


## A pass that must READ the device before the step records takes its own submit here. The step's first
## act is a sync, so nothing is in flight and the reading is of the state this step starts in.
func _pre_step() -> void:
	for p in _passes:
		if p.has_method("pre_step"):
			p.pre_step(_rd, _ctx, _cc, _groups)


## Signature: `probe.call(pass_index: int, pass_name: String)`, pass_index -1 = before any pass ran.
func set_step_probe(cb: Callable) -> void:
	_step_probe = cb


## Raw device readback of one buffer. Diagnostic only (the between-pass probe). No sync is done here — the
## checkpointed step already synced, and calling this off that path would read whatever the last sync left.
func read_raw(name: String) -> PackedFloat32Array:
	if _rd == null or not _bufs.has(name):
		return PackedFloat32Array()
	return _rd.buffer_get_data(_bufs[name]).to_float32_array()


## Raw device readback of one buffer as bytes, for integer buffers. Diagnostic only.
func read_raw_bytes(name: String) -> PackedByteArray:
	if _rd == null or not _bufs.has(name):
		return PackedByteArray()
	return _rd.buffer_get_data(_bufs[name])


## Sync an in-flight step submit WITHOUT reading channels — for save/load/dispose paths that touch buffers
## outside the normal begin/step/end loop. Leaves the mirrors untouched.
func _flush_pending() -> void:
	if not _pending:
		return
	_rd.sync()
	_pending = false


func _drain_pending() -> void:
	if not _pending:
		return
	var t0: int = Time.get_ticks_usec()
	_rd.sync()
	var t_sync: int = Time.get_ticks_usec()
	_pending = false
	_drain_count += 1
	_slow_gate += 1
	var read_slow: bool = _slow_gate >= SLOW_READBACK_EVERY
	if read_slow:
		_slow_gate = 0
	var want: PackedStringArray = _channel_names(read_slow)
	# A probe leg the drain is already reading is taken from that same copy; one it is not gets its own
	# staging slot. Either way it lands in its own dictionary, never in a mirror the simulation reads.
	var probe_names: PackedStringArray = PackedStringArray()
	for pname in _probe_want:
		if _bufs.has(pname) and not probe_names.has(pname):
			probe_names.append(pname)
	var srcs: Array = []
	for name in want:
		srcs.append(_bufs[String(name)])
	var probe_srcs: Array = []
	for name in probe_names:
		probe_srcs.append(_bufs[String(name)])
	if want.size() + probe_names.size() > _staging_slots:
		push_error("LAMaterialSphereGPU3D: %d buffers asked for and room for %d, so this drain read "
			% [want.size() + probe_names.size(), _staging_slots] + "nothing. Every reading it would "
			+ "have carried is ABSENT.")
		return
	# A sample belongs to the drain that produced it: replaced here every drain, never by a reader.
	_probe = _mirrors.drain(_staging, srcs, want, probe_srcs, probe_names)
	_probe_want = PackedStringArray()
	_field._atmos_dirty = true      # new h2o/temp -> invalidate the cached condensate aggregates
	# Direct sub-timings: how long the GPU sync stall vs the channel copy actually cost this drain.
	LASimReport.gauge("field_sync_ms", float(t_sync - t0) / 1000.0)
	LASimReport.gauge("field_readback_ms", float(Time.get_ticks_usec() - t_sync) / 1000.0)
	_drain_passes()


## The seeded field's derived state and its maxima, before any time passes. `sealing` marks the LAST
## derive of the seed: a reference taken over a world still being built names nothing.
func derive_seeded(sealing: bool = false) -> void:
	if _rd == null or _grid == null: return
	_ctx["cell_size"] = _grid.cell_size
	_ctx["cell_size_min"] = _grid.cell_size * pow(0.5, float(_grid.max_level))
	_ctx["seeding"] = not sealing
	for i in _passes.size():
		if not (_pass_names[i] in ["StateDerivePass", "ReducePass"]): continue
		var cl: int = _rd.compute_list_begin()
		_passes[i].dispatch(_rd, cl, _ctx, _cc, _groups)
		_rd.compute_list_end()
		_rd.submit()
		_rd.sync()
		_passes[i]._drain(_rd)
	_ctx.erase("seeding")


## Each pass's own readings; a pass owns its keys, and the first claimant of a key keeps it.
func _drain_passes() -> void:
	_pass_results = {}
	for i in _passes.size():
		var res: Dictionary = _passes[i]._drain(_rd)
		for key in res:
			var name: String = String(key)
			if _pass_results.has(name):
				push_error("%s publishes \"%s\", which another pass already published." % [_pass_names[i], name])
				continue
			_pass_results[name] = res[key]
			if typeof(res[key]) == TYPE_FLOAT or typeof(res[key]) == TYPE_INT:
				LASimReport.gauge(name, float(res[key]))


## The last drained reduce rows, gauged again once the report's baseline reset has wiped them.
func republish_latest() -> void:
	if LASimReport.gauge_cur("reduce_step", -1.0) >= 0.0:
		return
	for p in _passes:
		if not p.has_method("latest"):
			continue
		var rows: Dictionary = p.latest()
		for key in rows:
			if rows[key] is float or rows[key] is int:
				LASimReport.gauge(String(key), float(rows[key]))


## The compacted cell indices an `emit_idx` list published, empty when it listed nothing. Non-clearing.
func list_indices(label: String) -> PackedInt32Array:
	var v: Variant = _pass_results.get(label + "_list_idx", null)
	return v if v is PackedInt32Array else PackedInt32Array()


## The pass this world runs under `label` (its script's basename), or null where the rung holds none.
func pass_named(label: String):
	for i in _passes.size():
		if _pass_names[i] == label:
			return _passes[i]
	return null


## The merged pass readings of the last drained step, and clears them.
func take_pass_results() -> Dictionary:
	var out: Dictionary = _pass_results
	_pass_results = {}
	return out


## The channels THIS drain reads. A name absent from it keeps its older value, and `live()` says so.
func _channel_names(read_slow: bool) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray(["e_j_m3", "h2o", "o2"])
	# Derived: recomputed by StateDerivePass this step rather than carried.
	for k in LAChannels.derived_buffers():
		if _bufs.has(k) and not out.has(k):
			out.append(k)
	# Emergent WIND velocity (SINGLE, in-place) — wind3_at/wind_at expose a real force field that EVERY creature
	# samples per frame (LACreatureFieldForces), so it stays always-hot. CHARGE (breakdown→bolt firing) also has
	# a per-frame consumer with NO CPU-side trigger event to hook a request_channel() call to, so it stays hot too.
	for k in ["vel_x", "vel_y", "vel_z", "charge"]:
		if _bufs.has(k) and not out.has(k):
			out.append(k)
	for k in LAChannels.situational_channels():
		if not _bufs.has(k) or int(_channel_hold.get(k, -1)) < _drain_count or out.has(k):
			continue
		out.append(k)
	# SLOW — ledger/baker channels on the coarse cadence, from the table that declares which those ARE.
	if read_slow:
		for k in LAChannels.slow_channels():
			if _bufs.has(k) and not out.has(k):
				out.append(k)
	return out


func request_channel(name: String) -> void:
	_channel_hold[name] = _drain_count + CHANNEL_HOLD_DRAINS


func request_probe(names: PackedStringArray) -> void:
	for name in names:
		if not _probe_want.has(name):
			_probe_want.append(name)


## The most recent read-only sample, taken at the drain into a dictionary no simulation consumer sees. Empty
## until the first drain after `request_probe`; a leg that is absent is ABSENT, never substituted.
## Reading does not consume: every instrument that named a leg reads the same drain's measurement.
func take_probe(names: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for name in names:
		if _probe.has(name):
			out[name] = _probe[name]
	return out


## The CPU solid/static mask changed (initial solidity sample, a volcano SDF stamp, a terrain edit) — re-seed
## the GPU solid/static buffers on the next begin_frame instead of every step.
func mark_solid_dirty() -> void:
	_solid_dirty = true


## SEEDING ONLY: hands the device a whole channel while the world is being built. The amount is declared to
## LAMaterialFieldSeal3D, which refuses it once the world is SEALED.
func seed_field(name: String, seal) -> void:
	if _rd == null or not _bufs.has(name) or not _mirrors.has(name):
		return
	if _step_index > 0:
		push_error(("seed_field('%s') after %d steps: a whole-mirror upload past step 0 rewinds live GPU state " +
			"by an amount that depends on channel residency. Queue a sparse edit instead.") % [name, _step_index])
		return
	if seal == null:
		push_error(("seed_field('%s'): no seal to declare to. Handing the device a whole channel CREATES what " +
			"it holds, and an undeclared creation is a violation — pass LAMaterialField3D._seal.") % name)
		return
	var total: float = _mirrors.sum(name)
	# A re-upload REPLACES the buffer, so the manifest takes the difference.
	if not seal.note_creation("seed_" + name, total - float(_seed_totals.get(name, 0.0))):
		return
	_seed_totals[name] = total
	if name == "e_j_m3":
		_h_dirty = true         # keep the gated begin_frame upload in step with a whole-mirror seed
	_upload_mirror(name)


# --- SPARSE IN-PLACE EDITS (the only legal step-time write) -----------------------------------------------

## Hand the InjectPass one step's queued edits. It names its own cells, so nothing here reads a channel
## back and the cost is the batch's size, not the grid's.
func queue_sparse(ops: Array) -> void:
	if _rd == null or _inject == null or ops.is_empty():
		return
	_inject.plan(ops)
	for op: Dictionary in ops:
		request_channel(String(op["src"]))
		request_channel(String(op["dst"]))
	_wake_field()


## Cumulative amount injection has added to `channel` with no source in the field, as the device applied it.
func inject_created(channel: String) -> float:
	return _inject.created_total(channel) if _inject != null else 0.0


func dispose() -> void:
	if _rd == null:
		return
	_flush_pending()        # ensure the GPU is idle (no in-flight step submit) before freeing any RID
	for p in _passes:
		if p != null and p.has_method("dispose"):
			p.dispose(_rd)
	_passes = []
	_pass_names = PackedStringArray()
	for k in _bufs:
		var b: RID = _bufs[k]
		if b.is_valid():
			_rd.free_rid(b)
	_bufs = {}
	if _staging.is_valid():
		_rd.free_rid(_staging)
	_staging = RID()
	_driver = null
	_rd.free()
	_rd = null


# --- helpers ------------------------------------------------------------------

func _new_f(n: int) -> RID:
	var z: PackedByteArray = _zeros(n)
	return _rd.storage_buffer_create(z.size(), z)

## Seed a channel from a walk's own result, which lands in the mirror it belongs to first.
func _seed(name: String, arr: PackedFloat32Array) -> void:
	if not _bufs.has(name) or arr.size() != _cc:
		push_error("LAMaterialSphereGPU3D._seed: %s has no buffer or %d values over %d cells; nothing uploaded." % [name, arr.size(), _cc])
		return
	_mirrors.set_array(name, arr)
	_upload_mirror(name)

func _seed_regolith() -> void:
	LAFieldCellMass3D.upload_regolith(_rd, _bufs, _field)


## Seeded rock is bedrock, so it is both present and fully consolidated. Declared where it lands.
func _seed_silicate() -> void:
	seed_field("silicate", _field._seal)
	seed_field("cement", _field._seal)
	for name in LAPlanetComposition.shell_channels():
		if String(name) != "silicate":
			seed_field(String(name), _field._seal)
	seed_field("metal", _field._seal)

## One channel's mirror to its device buffer, straight out of native storage.
func _upload_mirror(name: String) -> void:
	var b: PackedByteArray = _mirrors.bytes(name, 0, _cc)
	if b.size() == _cc * 4:
		_rd.buffer_update(_bufs[name], 0, b.size(), b)
		_wake_field()


## A CPU write is a change no kernel saw, so every cell is awake again and the bubbles regrow.
func _wake_field() -> void:
	for p in _passes:
		if p.has_method("wake_all"):
			p.wake_all()

func _zeros(n: int) -> PackedByteArray:
	var a: PackedFloat32Array = PackedFloat32Array()
	a.resize(n)
	return a.to_byte_array()
