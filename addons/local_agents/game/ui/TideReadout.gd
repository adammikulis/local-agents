class_name LATideReadout
extends VBoxContainer

## THE TIDE AT THE SITE, read off the same integrator the probes fall through: the height water standing
## on the total equipotential reaches here, and where the body raising it stands over the horizon.

## Metres of tide per unit of tidal potential is 1/g, so the site's own g is what the height is read at.
const ROWS: Array = [["Tide", "%+.0f m"], ["Raiser", "%.0f° from overhead"]]

var _eye: Node3D = null
var _values: Dictionary


func setup(eye: Node3D) -> void:
	_eye = eye


## True where this world has a tide to read: a body to stand on and another one pulling on it.
static func active() -> bool:
	return LAFieldVectors.has_source(LAFieldVectors.SOURCE_TIDE)


func _ready() -> void:
	add_theme_constant_override("separation", 2)
	var head: Label = Label.new()
	head.text = "Equilibrium tide"
	add_child(head)
	var built: Dictionary = {}
	for spec: Array in ROWS:
		var row: HBoxContainer = HBoxContainer.new()
		var key: Label = Label.new()
		key.text = String(spec[0])
		key.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(key)
		var value: Label = Label.new()
		value.text = "—"
		row.add_child(value)
		add_child(row)
		built[String(spec[0])] = value
	_values = built
	refresh()


## The site: the point on the surface of the body under the eye. A world whose system is unpublished
## reads em dashes, never zeroes.
func refresh() -> void:
	var site: Vector3 = _site()
	var g: float = LABallistics.g_at(site).length() if site.is_finite() else 0.0
	if not site.is_finite() or g <= 0.0:
		for spec: Array in ROWS:
			(_values[String(spec[0])] as Label).text = "—"
		return
	(_values["Tide"] as Label).text = String(ROWS[0][1]) % (-LABallistics.tidal_potential_at(site) / g)
	var zenith: float = _raiser_zenith_deg(site)
	(_values["Raiser"] as Label).text = "—" if is_nan(zenith) else String(ROWS[1][1]) % zenith


## Where the eye stands, brought down to the surface of the body it stands on: the tidal potential grows
## as the square of the radius, so a reading taken from orbit is not the reading at the shore.
func _site() -> Vector3:
	if _eye == null or not is_instance_valid(_eye):
		return Vector3.INF
	var eye: Vector3 = _eye.global_position
	var i: int = LABallistics.dominant(eye)
	var r: float = LABallistics.body_radius(i)
	if i < 0 or not (r > 0.0):
		return Vector3.INF
	var centre: Vector3 = LABallistics.body_center(i)
	var out: Vector3 = eye - centre
	return centre + out.normalized() * r if out.length() > 0.0 else Vector3.INF


## Degrees from the local vertical to the body raising the largest tide here, 2 GM R / d^3 apiece.
## NAN where the system holds nothing but the body under the eye.
func _raiser_zenith_deg(site: Vector3) -> float:
	var i: int = LABallistics.dominant(site)
	var centre: Vector3 = LABallistics.body_center(i)
	var radius: float = LABallistics.body_radius(i)
	var best: float = 0.0
	var toward: Vector3 = Vector3.ZERO
	for k in LABallistics.system_size():
		if k == i:
			continue
		var off: Vector3 = LABallistics.body_center(k) - centre
		var d: float = off.length()
		if d <= 0.0:
			continue
		var amp: float = 2.0 * LABallistics.body_mu(k) * radius / (d * d * d)
		if amp > best:
			best = amp
			toward = off / d
	if best <= 0.0:
		return NAN
	var up: Vector3 = (site - centre).normalized()
	return rad_to_deg(acos(clampf(up.dot(toward), -1.0, 1.0)))
