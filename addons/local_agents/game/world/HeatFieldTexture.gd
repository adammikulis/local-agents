@tool
class_name LAHeatFieldTexture
extends Node

## The terrain shader's window onto the field and its star: per leaf of the graded grid its Morton code,
## temperature °C, water mol/m^3 and frozen share, and one texel for the star. Every block's copy of the
## terrain material shares these textures, so an upload reaches all of them, straight from native memory.

@export_group("Upload")
## Render frames between two uploads of the field's state: how fresh the ground looks, not how fast it steps.
@export_range(1, 60) var frames_per_upload: int = 3

## Texels per row of every per-leaf texture.
const ROW: int = 4096
## The channel each texture carries, and the shader uniform it lands on.
const CHANNELS: Dictionary = {"temp": "field_temp", "h2o": "field_h2o", "h2o_solid": "field_h2o_solid"}

# CIE 1931 2-degree observer, Wyman, Sloan & Shirley 2013 (JCGT 2(2)), multi-lobe fit: per lobe the
# channel (x y z), weight, mean nm, and the spread below and above the mean, nm.
const CIE1931_LOBES: Array = [
	[0, 1.056, 599.8, 37.9, 31.0], [0, 0.362, 442.0, 16.0, 26.7], [0, -0.065, 501.1, 20.4, 26.2],
	[1, 0.821, 568.8, 46.9, 40.5], [1, 0.286, 530.9, 16.3, 31.1],
	[2, 1.217, 437.0, 11.8, 36.0], [2, 0.681, 459.0, 26.0, 13.8],
]
# CIE XYZ to linear sRGB, IEC 61966-2-1:1999; the columns are X, Y and Z.
const XYZ_TO_SRGB: Basis = Basis(Vector3(3.2406, -0.9689, 0.0557), Vector3(-1.5372, 1.8758, -0.2040),
	Vector3(-0.4986, 0.0415, 1.0570))
# The band the CIE tabulates the observer over (CIE 2018), and ASTM E308's abridged interval, nm.
const VISIBLE_NM: Vector2 = Vector2(380.0, 780.0)
const BAND_NM: float = 10.0

var _field = null
var _star: LAStar = null
var _cells: int = 0
var _rows: int = 0
var _tex: Dictionary = {}              # channel -> ImageTexture
var _img: Dictionary = {}              # channel -> Image
var _star_img: Image = null
var _star_tex: ImageTexture = null
var _tick: int = 0


func setup(field, terrain) -> void:
	if field == null or terrain == null or not terrain.has_method("terrain_node"):
		return
	var grid: LAVoxelGrid = field._grid
	if grid == null or grid.cell_count <= 0:
		return
	_field = field
	_star = field._star
	_cells = grid.cell_count
	_rows = ceili(float(_cells) / float(ROW))
	# The field's frame turns about its pivot and the terrain's about its own origin, by the same rotation.
	var pivot: Vector3 = field.centre()
	var params: Dictionary = {
		"field_dims": Vector3i(grid.nx, grid.ny, grid.nz), "field_cell_m": grid.cell_size,
		"field_box_min": terrain.terrain_node().to_local(pivot) + (grid.origin - pivot),
		"field_morton_side": 1 << LAGridGeometry.MAX_LEVEL,
		"field_base_head": _int_texture(grid.base_head), "field_base_leaves": _int_texture(grid.base_leaves),
		"field_leaf_codes": _int_texture(grid.cell_morton),
		"kelvin_offset": LAPhysical.KELVIN_OFFSET,
		"snow_present": LAMaterialField3D.SNOW_PRESENT, "ice_depth": LAMaterialField3D.ICE_DEPTH,
		"planck_observer": ImageTexture.create_from_image(observer_table()),
	}
	for key in CHANNELS:
		_img[key] = Image.create_empty(ROW, _rows, false, Image.FORMAT_RF)
		_tex[key] = ImageTexture.create_from_image(_img[key])
		params[CHANNELS[key]] = _tex[key]
	_star_img = Image.create_empty(1, 1, false, Image.FORMAT_RGF)
	_star_img.set_pixel(0, 0, _star_texel())
	_star_tex = ImageTexture.create_from_image(_star_img)
	params["star_tex"] = _star_tex
	LATerrainLook.set_params(terrain.terrain_node(), params)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _tex.is_empty():
		return
	_tick += 1
	if _tick < frames_per_upload:
		return
	_tick = 0
	var mirrors: LAFieldMirrors = _field._mirrors
	if mirrors == null or mirrors.cells() != _cells:
		return
	for key in CHANNELS:
		_upload(mirrors, String(key))
	_star_img.set_pixel(0, 0, _star_texel())
	_star_tex.update(_star_img)


## One mirror to one texture: leaf c is texel (c % ROW, c / ROW), the rows past the last leaf left zero.
func _upload(mirrors: LAFieldMirrors, key: String) -> void:
	if not mirrors.has(key):
		return
	var bytes: PackedByteArray = mirrors.bytes(key, 0, _cells)
	bytes.resize(ROW * _rows * 4)
	_img[key].set_data(ROW, _rows, false, Image.FORMAT_RF, bytes)
	_tex[key].update(_img[key])


## An int32 per texel, as the four bytes of an RGBA8 texel the shader reassembles.
func _int_texture(values: PackedInt32Array) -> ImageTexture:
	var rows: int = maxi(ceili(float(values.size()) / float(ROW)), 1)
	var bytes: PackedByteArray = values.to_byte_array()
	bytes.resize(ROW * rows * 4)
	return ImageTexture.create_from_image(Image.create_from_data(ROW, rows, false, Image.FORMAT_RGBA8, bytes))


## THE STAR AS THE BODY SEES IT: its photosphere temperature, the luminosity over its surface through
## Stefan-Boltzmann, and the sine squared of its angular radius at the body's centre. Black, which the
## shader reads as no unit and so no glow, when the field lights with no star.
func _star_texel() -> Color:
	if _star == null or not is_instance_valid(_star):
		return Color(0.0, 0.0, 0.0)
	var r_m: float = float(_star.seed_row().get("radius_m", -1.0))
	var d_m: float = (_star.global_position - _field.centre()).length()
	var l_w: float = _star.luminosity_w()
	if not (r_m > 0.0 and d_m > r_m and l_w > 0.0):
		return Color(0.0, 0.0, 0.0)
	var t_k: float = pow(l_w / (4.0 * PI * r_m * r_m * LAPhysical.STEFAN_BOLTZMANN), 0.25)
	return Color(t_k, (r_m / d_m) * (r_m / d_m), 0.0)


## THE EYE'S RESPONSE OVER THE VISIBLE BAND, one texel per band: the CIE 1931 observer in linear sRGB times
## the first radiation constant 2 h c^2 over lambda^5 times the band, W m^-2 sr^-1 (rgb), and the second
## radiation constant h c / k over lambda, K (a). A Planck emitter's colour is the sum over the bands.
static func observer_table() -> Image:
	var h: float = LAPhysical.PLANCK_J_S
	var c: float = LAPhysical.SPEED_OF_LIGHT_M_S
	var bands: int = int(round((VISIBLE_NM.y - VISIBLE_NM.x) / BAND_NM))
	var img: Image = Image.create_empty(bands, 1, false, Image.FORMAT_RGBAF)
	for i in bands:
		var nm: float = VISIBLE_NM.x + (float(i) + 0.5) * BAND_NM
		var lam: float = nm * 1.0e-9
		var rgb: Vector3 = XYZ_TO_SRGB * cie1931(nm) * (2.0 * h * c * c / pow(lam, 5.0) * BAND_NM * 1.0e-9)
		img.set_pixel(i, 0, Color(rgb.x, rgb.y, rgb.z, h * c / (LAPhysical.BOLTZMANN_J_K * lam)))
	return img


## The CIE 1931 2-degree colour-matching functions at `nm`.
static func cie1931(nm: float) -> Vector3:
	var xyz: Vector3 = Vector3.ZERO
	for lobe in CIE1931_LOBES:
		var t: float = (nm - float(lobe[2])) / (float(lobe[3]) if nm < float(lobe[2]) else float(lobe[4]))
		xyz[int(lobe[0])] += float(lobe[1]) * exp(-0.5 * t * t)
	return xyz


func _get_configuration_warnings() -> PackedStringArray:
	if frames_per_upload < 1:
		return PackedStringArray(["Frames Per Upload is below one, so the field never reaches the ground."])
	return PackedStringArray()
