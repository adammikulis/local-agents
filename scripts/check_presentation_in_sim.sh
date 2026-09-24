#!/usr/bin/env bash
# PRESENTATION MAY NOT LIVE ON THE SIM SIDE. Counts, under addons/local_agents/sim/, every construction of
# a visual type, every read of the effects preset, and every load, by literal or through a String constant,
# of a game/render or game/ui resource, a rendering shader, a visual .tres, or a scene holding a visual node.
# A view belongs under game/render/ as a scene that reads sim state. May fall, may not rise.
# EXIT 0 at or under the ceiling · 1 rose, or slack on the dev branch · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
command -v require_tool >/dev/null 2>&1 && require_tool rg
SIM="$ROOT/addons/local_agents/sim"
[ -d "$SIM" ] || { echo "check_presentation_in_sim: MISSING $SIM" >&2; exit 2; }
CEIL_FILE="$ROOT/docs/PRESENTATION_IN_SIM_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_presentation_in_sim: no docs/PRESENTATION_IN_SIM_CEILING." >&2; exit 2; }
ceil="$(rg -N -e '^[0-9]+$' "$CEIL_FILE" 2>/dev/null | head -1)"
case "$ceil" in "" | *[!0-9]*) echo "check_presentation_in_sim: the ceiling carries no number." >&2; exit 2 ;; esac

TYPES='MultiMesh|MultiMeshInstance3D|MeshInstance3D|[A-Z][A-Za-z]*Mesh|[A-Z][A-Za-z0-9]*Material3D|ShaderMaterial|ParticleProcessMaterial|GPUParticles3D|CPUParticles3D|OmniLight3D|SpotLight3D|DirectionalLight3D|Label3D|Sprite3D|Decal|Control|CanvasLayer|Label|Button|Panel|[A-Z][A-Za-z]*Container'
VISUAL="\\b($TYPES)\\.new\\("
LOADS='(pre)?load\("res://addons/local_agents/game/(render|ui)/'
SHADERS='(pre)?load\("res://[^"]*\.gdshader(inc)?"'
PRESET='la_effects_scale'
hits="$(rg -n --glob '!**/thirdparty/**' -g '*.gd' -e "$VISUAL" -e "$LOADS" -e "$SHADERS" -e "$PRESET" "$SIM" \
	2>/dev/null | rg -v ':[0-9]+:[[:space:]]*#' || true)"
VISUAL_RES='^\[gd_resource type="[A-Za-z0-9]*(Material|Mesh|Texture|Shader|Sky|Environment|Theme|Font|StyleBox)'

# A node the scene declares, or one declared by a scene it instances, is a visual type.
visual_scene() {  # <repo-relative .tscn> <depth>
	local f="$ROOT/$1" id sub
	[ -f "$f" ] || return 1
	rg -q -e "^\[node .* type=\"($TYPES)\"" "$f" && return 0
	[ "$2" -lt 8 ] || return 1
	while IFS= read -r id; do
		[ -n "$id" ] || continue
		sub="$(rg -N -F " id=\"$id\"" "$f" | sed -n 's/^\[ext_resource .* path="res:\/\/\([^"]*\.tscn\)".*/\1/p' | head -1)"
		[ -n "$sub" ] && visual_scene "$sub" $(($2 + 1)) && return 0
	done <<< "$(sed -n 's/^\[node .* instance=ExtResource("\([^"]*\)").*/\1/p' "$f")"
	return 1
}

presentation() {  # <repo-relative path>
	case "$1" in
		addons/local_agents/game/render/* | addons/local_agents/game/ui/* | *.gdshader | *.gdshaderinc) return 0 ;;
		*.tres | *.material) [ -f "$ROOT/$1" ] && head -1 "$ROOT/$1" | rg -q -e "$VISUAL_RES" ;;
		*.tscn) visual_scene "$1" 0 ;;
		*) return 1 ;;
	esac
}

# The path a String constant names: NAME in the loading file, Class.NAME in the file declaring Class.
const_path() {  # <file> <NAME | Class.NAME>
	local file="$1" name="$2"
	if [ "${name#*.}" != "$name" ]; then
		file="$(rg -l --glob '!**/thirdparty/**' -g '*.gd' -e "^class_name ${name%%.*}\$" "$ROOT/addons" 2>/dev/null | head -1)"
		name="${name#*.}"
	fi
	[ -n "$file" ] || return 0
	sed -nE "s/^const ${name}([[:space:]]*:[^=]*)?[[:space:]]*=[[:space:]]*\"res:\/\/([^\"]*)\".*/\2/p" "$file" | head -1
}

# Every load the literal arms above did not count, resolved to what it loads.
LITERAL='^"res://([^"]*)"$'
CONSTANT='^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$'
while IFS= read -r site; do
	[ -n "$site" ] || continue
	printf '%s' "$site" | rg -q -e "$LOADS" -e "$SHADERS" && continue
	arg="$(printf '%s' "${site#*:*:}" | sed -n 's/.*load(\([^)]*\)).*/\1/p')"
	path=""
	if [[ "$arg" =~ $LITERAL ]]; then
		path="${BASH_REMATCH[1]}"
	elif [[ "$arg" =~ $CONSTANT ]]; then
		path="$(const_path "${site%%:*}" "$arg")"
	fi
	[ -n "$path" ] && presentation "$path" && hits="${hits:+$hits$'\n'}$site"
done <<< "$(rg -n --glob '!**/thirdparty/**' -g '*.gd' -e '\b(pre)?load\(' "$SIM" 2>/dev/null \
	| rg -v ':[0-9]+:[[:space:]]*#' || true)"
n=0
[ -n "$hits" ] && n="$(printf '%s\n' "$hits" | rg -c . || echo 0)"
echo "PRESENTATION_IN_SIM={\"count\":$n,\"ceiling\":$ceil}"
if [ "$n" -gt "$ceil" ]; then
	echo "check_presentation_in_sim: $n presentation site(s) under sim/ against a ceiling of $ceil." >&2
	echo "               Move the look into a scene under game/render/ that reads sim state." >&2
	printf '%s\n' "$hits" >&2
	exit 1
fi
if [ "$n" -lt "$ceil" ] && [ "$(ceiling_strict "$ROOT" 2>/dev/null || echo 0)" = "1" ]; then
	echo "check_presentation_in_sim: $n against a ceiling of $ceil — write the tighter number." >&2
	exit 1
fi
echo "check_presentation_in_sim: OK ($n presentation site(s) under sim/ against a ceiling of $ceil)."
