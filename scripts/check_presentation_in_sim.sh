#!/usr/bin/env bash
# PRESENTATION MAY NOT LIVE ON THE SIM SIDE. Counts, under addons/local_agents/sim/, every construction of a
# visual type, every load of a game/render or game/ui resource, every read of the effects preset and every
# sound played.
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

VISUAL='\b(MultiMesh|MultiMeshInstance3D|MeshInstance3D|[A-Z][A-Za-z]*Mesh|[A-Z][A-Za-z0-9]*Material3D|ShaderMaterial|ParticleProcessMaterial|GPUParticles3D|CPUParticles3D|OmniLight3D|SpotLight3D|DirectionalLight3D|Label3D|Sprite3D|Decal|Control|CanvasLayer|Label|Button|Panel|[A-Z][A-Za-z]*Container)\.new\('
LOADS='(pre)?load\("res://addons/local_agents/game/(render|ui)/'
PRESET='la_effects_scale'
SOUND='\bLAAudioDirector\b|\.play_sfx\(|\bAudioStreamPlayer(2D|3D)?\.new\('
hits="$(rg -n --glob '!**/thirdparty/**' -g '*.gd' -e "$VISUAL" -e "$LOADS" -e "$PRESET" -e "$SOUND" "$SIM" 2>/dev/null \
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
