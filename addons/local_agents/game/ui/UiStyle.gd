class_name LAUiStyle
extends RefCounted

## The one declaration of the HUD palette and the flat box every panel is built from. A colour declared in
## two files drifts the day one of them is edited.

const COL_BG: Color = Color(0.086, 0.098, 0.129, 0.94)
const COL_BG_2: Color = Color(0.129, 0.145, 0.184, 0.96)
const COL_BORDER: Color = Color(0.24, 0.27, 0.33, 1.0)
const COL_ACCENT: Color = Color(0.33, 0.70, 0.98, 1.0)
const COL_ACCENT_DIM: Color = Color(0.33, 0.70, 0.98, 0.22)
const COL_TEXT: Color = Color(0.90, 0.92, 0.95, 1.0)
const COL_TEXT_DIM: Color = Color(0.62, 0.66, 0.72, 1.0)
const COL_TEXT_HEADING: Color = Color(0.98, 0.99, 1.0, 1.0)
const COL_GOLD: Color = Color(1.0, 0.82, 0.36, 1.0)

const CORNER_RADIUS: int = 10

## A panel's flat box. The corner radius and the zero content margin are the shared fact; the border and
## the shadow are the caller's, because a toast and a palette panel are meant to read differently.
static func flat_box(bg: Color, border: Color, border_width: int,
		shadow_alpha: float, shadow_size: int) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(CORNER_RADIUS)
	sb.set_border_width_all(border_width)
	sb.border_color = border
	sb.set_content_margin_all(0)
	sb.shadow_color = Color(0, 0, 0, shadow_alpha)
	sb.shadow_size = shadow_size
	return sb
