#!/usr/bin/env bash
# THE LADDER. Each rung is a smaller world that is physically complete on its own, and a rung is enabled
# only when the rung below it is green. This runs them bottom-up, stops at the first red one and names
# it, and never examines a rung above it. Every rung takes one short arm at its own rung for the cost
# reading, then its own gates; rung 8's gate is the conservation soak, so nobody blocks on this.
# EXIT 0 every selected rung is green · 1 a rung is red · 2 a rung's run or gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_godot.sh"
. "$ROOT/scripts/lib_lint_queue.sh"

THROUGH_RUNG=""
FRAMES="${LA_LADDER_FRAMES:-8}"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }

# --slice climbs a BOX rather than the whole planet. The box is sim_run.sh's, which is where that literal
# is declared; an explicit spec overrides it. Said first, because a reader must know which world was climbed.
while [ $# -gt 0 ]; do
  case "$1" in
    --through-rung)
      [ $# -ge 2 ] || { echo "check_process_ladder: --through-rung needs a rung." >&2; exit 2; }
      case "$2" in ""|*[!0-9]*) echo "check_process_ladder: invalid rung '$2'." >&2; exit 2 ;; esac
      THROUGH_RUNG="$2"
      shift 2
      ;;
    --slice)
      shift
      case "${1:-}" in
        ""|--*) LA_LADDER_SLICE="$("$ROOT/scripts/sim_run.sh" --print-slice-box)" ;;
        *) LA_LADDER_SLICE="$1"; shift ;;
      esac
      export LA_LADDER_SLICE
      ;;
    *) echo "check_process_ladder: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -n "${LA_LADDER_SLICE:-}" ]; then
  export LA_LADDER_SLICE
  printf 'LADDER_ARM={"slice":"%s"}\n' "$LA_LADDER_SLICE"
else
  printf 'LADDER_ARM={"slice":null}\n'
fi

LADDER_TIMING="$(mktemp "${TMPDIR:-/tmp}/la_ladder_timing.XXXXXX")" || exit 2
TIMEFORMAT='%R'
la_timed() {  # la_timed <label> <command...> — runs it, records its wall seconds, returns its status
  local label="$1"
  shift
  local el rc
  exec 3>&1
  el="$( { time "$@" 1>&3 2>&3; } 2>&1 1>&3 )"
  rc=$?
  printf '%s\t%s\n' "$el" "$label" >> "$LADDER_TIMING"
  return "$rc"
}

# THE RUNGS AND THEIR GATES, read out of LAProcessSet so this script keeps no second copy of the table.
PROBE_REL="addons/local_agents/tests/zz_ladder_list.gd"
PROBE="$ROOT/$PROBE_REL"
trap 'rm -f "$PROBE" "$PROBE.uid" "$LADDER_TIMING"' EXIT INT TERM
cat > "$PROBE" <<'GD'
extends SceneTree

func _init() -> void:
	for r: Dictionary in LAProcessSet.rungs():
		print("LADDER_ROW=%d\t%s\t%s" % [int(r["rung"]), String(r["name"]),
			" ".join(PackedStringArray(r["gates"]))])
	quit(0)
GD
rows="$(la_godot --headless --path "$ROOT" -s "res://$PROBE_REL" 2>&1 | grep '^LADDER_ROW=')"
rm -f "$PROBE" "$PROBE.uid"
if [ -z "$rows" ]; then
  echo "ERROR: LAProcessSet published no rungs, so there is no ladder to climb." >&2
  exit 2
fi

if [ -n "$THROUGH_RUNG" ]; then
  if ! printf '%s\n' "$rows" | grep -Eq "^LADDER_ROW=${THROUGH_RUNG}"$'\t'; then
    echo "check_process_ladder: rung '$THROUGH_RUNG' is absent from the process registry." >&2
    exit 2
  fi
  printf 'LADDER_LIMIT={"through_rung":%s,"higher_rungs":"not examined"}\n' "$THROUGH_RUNG"
fi

# THE ASSIGNMENT FIRST. A process in no rung would run at every rung or at none, and no rung below is
# then the world it claims to be.
if ! "$ROOT/scripts/check_process_set.sh"; then
  echo "ERROR: the process set is not fully assigned, so no rung is the world it claims to be." >&2
  exit 2
fi

green=-1
green_name="none"
red_name=""
red_gate=""
rc_out=0

while IFS=$'\t' read -r tag name gates; do
  n="${tag#LADDER_ROW=}"
  if [ -n "$THROUGH_RUNG" ] && [ "$n" -gt "$THROUGH_RUNG" ]; then break; fi
  echo
  echo "=== rung $n $name ==="
  t0=$(date +%s)
  arm="$(la_rung_report "$n" "$FRAMES" "step_ms,field_ms,transport_levels")"
  arm_rc=$?
  t1=$(date +%s)
  wall=$((t1 - t0))
  printf '%s\trung %s %s (arm)\n' "$wall" "$n" "$name" >> "$LADDER_TIMING"
  step="$(la_rung_value "$arm" step_ms)"
  [ -n "$step" ] || step="$(la_rung_value "$arm" field_ms)"
  levels="$(la_rung_value "$arm" transport_levels)"
  # A rung with no transport publishes no level count; that is absent, never zero.
  printf 'LADDER_RUNG={"rung":%s,"name":"%s","step_ms":%s,"wall_s":%d,"transport_levels":%s}\n' \
    "$n" "$name" "${step:-null}" "$wall" "${levels:-null}"
  case "$arm_rc" in
    0) ;;
    122 | 123 | 126)
      # The run COMPLETED and one of the sim's own audits fired. That is this rung's verdict, and it
      # outranks whatever its gates would have said, because they would read the same broken world.
      echo "The rung's own run reported a verdict (sim_run exit $arm_rc):" >&2
      printf '%s\n' "$arm" | grep -E '^(PRESSURE_BROKEN|CONSERVATION_VIOLATION|CONSERVATION_UNMEASURED)' \
        | head -4 >&2
      red_name="$name"
      rc_out=1
      break
      ;;
    *)
      echo "ERROR: rung $n ($name) could not complete its run (sim_run exit $arm_rc)." >&2
      printf '%s\n' "$arm" | tail -15 >&2
      red_name="$name"
      rc_out=2
      break
      ;;
  esac
  for g in $gates; do
    if [ ! -x "$ROOT/scripts/$g" ] && [ ! -f "$ROOT/scripts/$g" ]; then
      echo "ERROR: rung $n ($name) names gate $g, which is not in scripts/." >&2
      red_name="$name"
      red_gate="$g"
      rc_out=2
      break 2
    fi
    echo "--- $g"
    la_timed "$g" bash "$ROOT/scripts/$g"
    grc=$?
    if [ "$grc" -ne 0 ]; then
      red_name="$name"
      red_gate="$g"
      rc_out=$([ "$grc" -eq 1 ] && echo 1 || echo 2)
      break 2
    fi
  done
  green="$n"
  green_name="$name"
done <<< "$rows"

echo
if [ -n "$red_name" ]; then
  echo "The ladder stops at rung \"$red_name\"${red_gate:+ ($red_gate)}. Every rung above it is NOT"
  echo "examined: a reading taken over a broken rung is the interaction of two defects, not a measurement."
fi
printf 'LADDER={"green":"%s","first_red":"%s","frames":%s}\n' "$green_name" "${red_name:-none}" "$FRAMES"
la_timing_line "$LADDER_TIMING" LADDER_TIMING

exit "$rc_out"
