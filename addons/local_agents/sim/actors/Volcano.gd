class_name LAVolcano
extends Node3D

## A volcano is NOT a scripted eruption. It is a VENT (a seed/marker) that does ONE authored thing: drive a
## SUSTAINED lava supply at a fixed spot on the terrain. EVERYTHING downstream EMERGES from the shared substrate
## with zero volcano code:
##   • erupt_source() extrudes deep-mantle lava into the OPEN seawater cell at the growing surface front;
##   • it spreads into a mound as more piles up (lava_flow);
##   • underwater it QUENCHES on contact with seawater (the marine-lava heat sink) and, cooled below the solidus,
##     the M5 reaction record freezes it to rock_fill;
##   • rock_fill crossing 0.5 STAMPS the SDF terrain upward (MineralStamp3D), so the cone accretes;
##   • repeated supply piles the cone until it BREACHES the sea surface = a NEW ISLAND (the capstone), all from
##     eruption + water-quench solidification + rock accumulation + SDF growth composing. Nothing here says "island".
##
## HOW THE CONE PILES AT ONE SPOT: each supply tick deposits at the CURRENT surface top along the vent radial
## (tracking the growing cone), so lava always emerges into the open water at the front where the cell above is
## sea. The pile climbs, never plugs. The vent node rides the planet body, so that radial follows the spin.
##
## This used to need help. The MaterialField grid was WORLD-FIXED while the body SPUN, so over a long accretion
## the field's rock_fill and the terrain SDF stopped describing the same place and the cone SMEARED into an arc
## — and VoxelWorld froze the planet's rotation for the --auto-seavolcano demo to hide it. The field is
## body-local now (LAMaterialField3D.sync_body_frame / dir_to_field / point_to_field), the freeze is gone, and
## cone_profile() below measures what the freeze was covering for: with the planet turning through ~1.6
## rotations over a 600-frame run, the accreted material's centroid stays within 0.02 rad of the vent radial
## (~9 units of arc on a 500-unit planet) and its major/minor half-width ratio stays near 1. It builds a round
## pile on one spot. Measured 2026-07-30 over five runs; see the SEAVOLCANO proof line.
##
## Deleted vs the old scripted volcano: `_is_erupting`, `_bomb_cd`, `BOMBS_PER_BURST`/`BOMB_*`, `_launch_bombs`,
## the bomb GPUParticles/RigidBody emitter, `_bomb_impact`, the burst timer and pressure state machine. A thrown
## rock ("bomb"), a geyser, an island are all just words for what the one substrate does. (Explicit types only.)

const SCARE_INTERVAL: float = 2.0
const SCARE_RADIUS: float = 55.0

# Sustained supply: molten mantle mineral erupted at the vent each SECOND while active. Generous — the supply must
# out-pace the underwater quench + lateral flow so the cone keeps accreting upward and breaches within a demo run.
const SUPPLY_PER_SEC: float = 16.0
const SUPPLY_INTERVAL: float = 0.05        # deposit cadence (s); many small deposits pile in one cell past MAX_MASS
# A vent is a DISC, not a 1-cell needle: scatter each deposit across a small angular disc around the vent radial so
# the erupted rock piles into a BROAD island cone instead of a single-column spire racing to the grid ceiling.
const VENT_DISC: float = 0.10              # angular radius of the vent disc (rad); ~ a handful of columns wide
#
# ISLAND_FREEBOARD = 14.0 USED TO SIT HERE, skipping any column whose surface already stood 14 units above sea so
# supply flowed to the submerged ones and "the island tops out as a low landmass rather than a runaway tower". It
# was deleted 2026-07-30 because it does not do that. Measured over 600-frame runs: with the cap in place the pile
# stands 107-116 units above sea level, eight times the freeboard it names, while the cap fires on 657 of 5120
# deposit attempts (13%). Removing it changes nothing outside run-to-run spread — rise 139.7/155.6 uncapped versus
# 144.2-149.8 capped, breach 97.9/114.3 versus 115.5-115.9, roundness and drift identical. It only ever chose WHICH
# column in the disc received the next deposit; the height is set downstream by quench/solidify/stamp, which no
# supply routing reaches. The runaway tower is REAL and still unsolved — the fix belongs in the substrate (the
# stamp's response to accumulated rock_fill), not in a supply-side skip that cannot see the spire it is aiming at,
# because surface_radius() casts a single ray that misses a one-cell-wide column. A clamp that does not clamp is
# worse than none: it told every reader this was handled.

# Seismic tremor emitted while supplying (camera shake / felt seismic EMERGES from the shared field, not here).
const ERUPT_SEISMIC: float = 3.0

# --- CONE-SHAPE TELEMETRY (the accretion's positional proof) -------------------------------------------
# "The cone piled at one spot" and "it smeared into an arc" are SHAPES, and no scalar the field already
# reports tells them apart. This measures the terrain CHANGE: a baseline radial profile is taken on a polar
# grid around the vent shortly after seeding, and at report time the same grid is re-read and subtracted, so
# what is left is exactly the material this vent added — the surrounding natural terrain cancels itself out.
# That delta is then reduced to its moments on the tangent plane: a compact cone is round (major/minor ~ 1)
# and centred on the vent (drift ~ 0); an arc is elongated along the direction the deposits walked. The grid
# is stored in BODY-LOCAL directions, so it rotates with the planet and asks about the same ground both
# times. It costs one raycast per sample, so it is pulled on a cadence by whoever wants it, never per frame.
const PROFILE_AZIMUTHS: int = 24
const PROFILE_RINGS: int = 14
const PROFILE_SPAN: float = 0.25           # sample out to this angular radius (rad) — 2.5x the vent disc
const PROFILE_RISE: float = 0.5            # ignore growth under this (units) — SDF/raycast noise, not accretion
const BASELINE_DELAY: float = 1.5          # s after seeding before the baseline is taken (let the patch stream in)

var _terrain: Object = null
var _ecology: Object = null
var _field: Object = null
var _inject: Object = null                  # the field's injection module (owns erupt_source; keeps the field small)
var _center: Vector3 = Vector3.ZERO         # planet centre (radial reference)
var _submerged_seed: bool = false           # true when seeded on the seabed (drives the "island" telemetry)

var _supply_cd: float = 0.0
var _scare_cd: float = 0.0
var _tremor_cd: float = 0.0
var _active: bool = true
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()   # seeded → a REPRODUCIBLE island (deterministic demo)

var _glow: OmniLight3D = null
var _picker: StaticBody3D = null

# Baseline radial profile (see CONE-SHAPE TELEMETRY): body-local sample directions, their tangent-plane
# offsets from the vent radial, and the surface radius each read before this vent had built anything.
var _base_dirs: PackedVector3Array = PackedVector3Array()
var _base_off: PackedVector2Array = PackedVector2Array()
var _base_r: PackedFloat32Array = PackedFloat32Array()
var _baseline_cd: float = -1.0              # >0 = counting down to the baseline capture; <0 = done/not armed

# Telemetry (read by --auto-seavolcano proof + the inspector): the vent's fixed radial + running deposit ledger.
var vent_dir_world: Vector3 = Vector3.UP    # snapshot of the vent radial at seed (world space, pre-spin)
var seed_surface_radius: float = 0.0        # surface radius at the vent when seeded (the "before" sea floor)
var total_supplied: float = 0.0             # Σ lava mass actually injected (conservation cross-check)


func _ready() -> void:
	add_to_group("selectable")
	_rng.seed = LASimRng.shared().randi()   # seeded from the sim stream so the island reproduces from LA_SIM_SEED


func setup(terrain: Object, ecology: Object) -> void:
	_terrain = terrain
	_ecology = ecology
	if _ecology != null and _ecology.has_method("material_field"):
		_field = _ecology.material_field()
	if _field != null:
		_inject = _field.get("_inject")     # reach the injection module (erupt_source lives there, not in the field)
	if _terrain != null and _terrain.has_method("planet_center"):
		_center = _terrain.planet_center()


## Seed the vent at a world `point` on the terrain surface (land or seabed). Stores the vent's radial and the
## initial surface radius; a seabed seed (below the sea shell) is what builds an island. The node is parented under
## the spinning body, so its global_position rides the terrain — supply tracks this one spot.
func erupt_at(point: Vector3) -> void:
	global_position = point
	vent_dir_world = (point - _center).normalized()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var sr: float = _terrain.surface_radius(vent_dir_world)
		if not is_nan(sr):
			seed_surface_radius = sr
	if _terrain != null and _terrain.has_method("sea_radius"):
		_submerged_seed = seed_surface_radius > 0.0 and seed_surface_radius < _terrain.sea_radius()
	if _submerged_seed:
		# Arm the cone-shape baseline: only a seabed vent builds an island, so only it needs the "before".
		# This is NOT registered with LASimReport. A run has several vents at once (the ambient director and
		# LAPlateTectonics both seed their own), any of which can land on a seabed, and a flat report key would
		# be won by whichever registered last — a confidently wrong number is worse than no number. The caller
		# that knows WHICH vent it is asks it directly (see the --auto-seavolcano SEAVOLCANO proof line).
		_baseline_cd = BASELINE_DELAY
	_build_fx()
	LAAudioDirector.emit(get_tree(), "crumble", point)


## Capture the "before" radial profile around the vent: a polar grid of BODY-LOCAL directions plus the
## surface radius each one reads right now. Taken once, a moment after seeding, so the terrain patch has
## streamed in. Everything the vent subsequently builds shows up as growth against these numbers.
func _capture_baseline() -> void:
	_base_dirs = PackedVector3Array()
	_base_off = PackedVector2Array()
	_base_r = PackedFloat32Array()
	if _terrain == null or not _terrain.has_method("surface_radius"):
		return
	var inv: Basis = global_transform.basis.inverse()   # world dir -> body-local (the node rides the body)
	var d: Vector3 = _vent_dir_now()
	var t1: Vector3 = d.cross(Vector3.UP)
	if t1.length() < 0.01:
		t1 = d.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2: Vector3 = d.cross(t1).normalized()
	for ri in range(PROFILE_RINGS + 1):
		var rad: float = PROFILE_SPAN * float(ri) / float(PROFILE_RINGS)
		var az_n: int = 1 if ri == 0 else PROFILE_AZIMUTHS   # one at the centre, a full sweep beyond
		for ai in range(az_n):
			var ang: float = TAU * float(ai) / float(az_n)
			var ox: float = cos(ang) * rad
			var oy: float = sin(ang) * rad
			var sdir: Vector3 = (d + t1 * ox + t2 * oy).normalized()
			var sr: float = _terrain.surface_radius(sdir)
			if is_nan(sr):
				continue                              # unmeshed patch — no baseline, so no later comparison
			_base_dirs.append(inv * sdir)
			_base_off.append(Vector2(ox, oy))
			_base_r.append(sr)


## Shape of what this vent actually built, measured as terrain GROWTH against the baseline profile. Costs
## one raycast per sample, so call it on a cadence, never per frame. Reports:
##   rise    90th-percentile column growth (units) — did the pile build UP? (a percentile, not a max: see below)
##   breach  that column's standing relative to sea level (>0 = a real island stands above the water)
##   smear   major/minor angular half-width of the grown material. ~1 = round cone; >>1 = smeared arc.
##   drift   angular distance (rad) from the vent radial to the grown material's centroid — 0 = on the vent
##   span    major angular half-width (rad), the pile's absolute size, so `smear` reads in context
##   cover   how many sampled columns grew, out of `samples` compared — a handful makes the moments noise
func cone_profile() -> Dictionary:
	var out: Dictionary = {"rise": 0.0, "breach": 0.0, "smear": 0.0, "drift": 0.0, "span": 0.0,
		"cover": 0, "samples": 0, "supplied": total_supplied, "seabed": seed_surface_radius}
	if _terrain == null or not _terrain.has_method("surface_radius") or _base_dirs.is_empty():
		return out
	var bas: Basis = global_transform.basis        # body-local dir -> world, at the planet's CURRENT rotation
	var sea: float = _sea_radius()
	# Zeroth/first/second moments of the grown material on the tangent plane, in one pass.
	var w_sum: float = 0.0
	var mx: float = 0.0
	var my: float = 0.0
	var mxx: float = 0.0
	var myy: float = 0.0
	var mxy: float = 0.0
	var cover: int = 0
	# Height is reported as a PERCENTILE, never a maximum. surface_radius() casts one ray inward, and the
	# planet has caves, so a ray that happens to drop through a void reads a near-core radius. That single
	# sample then dominates a max: one 600-frame run reported a 336-unit "rise" whose own sea-level standing
	# came out 30 units UNDERWATER, which is not a thing a pile can be. Sorting and taking p90 discards those
	# few punched rays and still answers "how tall did this build". The shape numbers below never had the
	# problem — they are weighted averages over ~150 columns, so a stray sample cannot move them.
	var grown: PackedVector2Array = PackedVector2Array()   # (growth, sea-level standing) per sampled column
	for i in range(_base_dirs.size()):
		var sr: float = _terrain.surface_radius(bas * _base_dirs[i])
		if is_nan(sr):
			continue                                # unmeshed now — no reading, not a zero reading
		var grew: float = sr - _base_r[i]           # terrain GROWTH here since the vent was seeded
		grown.append(Vector2(grew, sr - sea))
		var w: float = grew - PROFILE_RISE
		if w <= 0.0:
			continue
		var off: Vector2 = _base_off[i]
		cover += 1
		w_sum += w
		mx += w * off.x
		my += w * off.y
		mxx += w * off.x * off.x
		myy += w * off.y * off.y
		mxy += w * off.x * off.y
	out["cover"] = cover
	out["samples"] = grown.size()
	if not grown.is_empty():
		var by_growth: Array = Array(grown)
		by_growth.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
		var p90: Vector2 = by_growth[mini(by_growth.size() - 1, int(float(by_growth.size()) * 0.9))]
		out["rise"] = p90.x
		out["breach"] = p90.y
	if w_sum <= 0.0:
		return out
	# Centroid, then the covariance about it; the 2x2 symmetric eigenvalues are the squared half-widths.
	var cx: float = mx / w_sum
	var cy: float = my / w_sum
	var vxx: float = maxf(0.0, mxx / w_sum - cx * cx)
	var vyy: float = maxf(0.0, myy / w_sum - cy * cy)
	var vxy: float = mxy / w_sum - cx * cy
	var half: float = 0.5 * (vxx + vyy)
	var disc: float = sqrt(maxf(0.0, 0.25 * (vxx - vyy) * (vxx - vyy) + vxy * vxy))
	var major: float = sqrt(maxf(0.0, half + disc))
	var minor: float = sqrt(maxf(0.0, half - disc))
	out["drift"] = sqrt(cx * cx + cy * cy)
	out["span"] = major
	out["smear"] = major / maxf(minor, 1.0e-5)
	return out


## Legacy demo hook: a quick pulse of lava at the vent right now (kept so --auto-volcano still shows molten output
## immediately). The sustained supply below does the real work.
func force_erupt() -> void:
	_deposit(2.0)


func get_inspector_payload() -> Dictionary:
	var lines: Array = []
	lines.append("Kind: %s vent" % ("SEABED" if _submerged_seed else "subaerial"))
	lines.append("Vent radius: %.1f (sea %.1f)" % [_current_surface_radius(), _sea_radius()])
	lines.append("Lava supplied: %.0f" % total_supplied)
	if _submerged_seed:
		var breached: bool = _current_surface_radius() > _sea_radius()
		lines.append("Island: %s" % ("BREACHED SURFACE" if breached else "building underwater"))
	return {"title": "Volcano", "lines": lines}


func _sea_radius() -> float:
	if _terrain != null and _terrain.has_method("sea_radius"):
		return _terrain.sea_radius()
	return 0.0


# Current surface radius along the vent's SPINNING radial (tracks the terrain as it rotates + the cone as it grows).
func _current_surface_radius() -> float:
	var d: Vector3 = _vent_dir_now()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var sr: float = _terrain.surface_radius(d)
		if not is_nan(sr):
			return sr
	return seed_surface_radius


# The vent's radial RIGHT NOW: the node rides the body's spin, so its live position gives the current world radial.
func _vent_dir_now() -> Vector3:
	var d: Vector3 = global_position - _center
	if d.length() > 0.001:
		return d.normalized()
	return vent_dir_world


# Erupt `amount` of molten mantle mineral at the vent's current top. erupt_source injects it into the first OPEN cell
# above the surface (the seawater cell at the growing front), where it quenches + solidifies + stamps the terrain up.
# Depositing at the CURRENT surface radius (not the fixed seed) keeps the supply at the growing front so, as the cone
# climbs, the lava always emerges into open water instead of burying itself in the pile.
func _deposit(amount: float) -> void:
	if _inject == null or not _inject.has_method("erupt_source"):
		return
	# Scatter the deposit across the vent disc: a random direction within VENT_DISC of the vent radial (uniform on the
	# tangent disc) so the pile broadens into an island cone. Build a tangent frame around the vent radial.
	var d: Vector3 = _vent_dir_now()
	var t1: Vector3 = d.cross(Vector3.UP)
	if t1.length() < 0.01:
		t1 = d.cross(Vector3.RIGHT)
	t1 = t1.normalized()
	var t2: Vector3 = d.cross(t1).normalized()
	var ang: float = _rng.randf() * TAU
	# CENTRE-WEIGHTED radius (no sqrt → density peaks at the vent): the centre column leads and reliably breaches,
	# and the disc's outer draws fill in around it so the pile reads as one island rather than a lone needle.
	var rad: float = _rng.randf() * _rng.randf() * VENT_DISC
	var dir: Vector3 = (d + (t1 * cos(ang) + t2 * sin(ang)) * rad).normalized()
	# Deposit at THIS column's current surface, so the lava enters the open water at that column's own front.
	var sr: float = _current_surface_radius()
	if _terrain != null and _terrain.has_method("surface_radius"):
		var s: float = _terrain.surface_radius(dir)
		if not is_nan(s):
			sr = s
	var top: Vector3 = _center + dir * sr
	total_supplied += _inject.erupt_source(top, amount)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	# One-shot "before" profile for the cone-shape telemetry, once the terrain patch has had time to stream.
	if _baseline_cd > 0.0:
		_baseline_cd -= delta
		if _baseline_cd <= 0.0:
			_capture_baseline()
	# SUSTAINED SUPPLY — the one authored action. Many small deposits per second pile lava in the vent column past
	# MAX_MASS so magma buoyancy lifts it; the rest (quench, solidify, stamp, island) is pure emergent substrate.
	_supply_cd -= delta
	while _supply_cd <= 0.0:
		_supply_cd += SUPPLY_INTERVAL
		_deposit(SUPPLY_PER_SEC * SUPPLY_INTERVAL)

	# Emergent felt seismic (camera shake reads the field), throttled so a continuous tremor reads as overlapping pulses.
	_tremor_cd -= delta
	if _tremor_cd <= 0.0:
		_tremor_cd = 0.15
		if _ecology != null and _ecology.has_method("broadcast_seismic"):
			_ecology.broadcast_seismic(global_position, ERUPT_SEISMIC)

	# Scare wildlife on a cadence — the SAME broadcast stimulus every disaster reuses (emergent flee, no per-case code).
	_scare_cd -= delta
	if _scare_cd <= 0.0:
		_scare_cd = SCARE_INTERVAL
		if _ecology != null and _ecology.has_method("broadcast_scare"):
			_ecology.broadcast_scare(global_position, SCARE_RADIUS, 0.7)

	if _glow != null:
		_glow.light_energy = lerpf(_glow.light_energy, 22.0, 0.1)


func _build_fx() -> void:
	if _glow == null:
		_glow = OmniLight3D.new()
		_glow.light_color = Color(1.0, 0.5, 0.15)
		_glow.omni_range = 26.0
		_glow.position = Vector3(0.0, 2.0, 0.0)
		add_child(_glow)
	if _picker == null:
		_picker = StaticBody3D.new()
		_picker.collision_layer = 2
		_picker.collision_mask = 0
		var col: CollisionShape3D = CollisionShape3D.new()
		var cs: SphereShape3D = SphereShape3D.new()
		cs.radius = 5.0
		col.shape = cs
		_picker.add_child(col)
		add_child(_picker)
