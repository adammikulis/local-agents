#!/usr/bin/env bash
# THE LADDER. Each rung is a smaller world that is physically complete on its own, and a rung is enabled
# only when the rung below it is green. This runs them bottom-up, stops at the first red one and names
# it, and never examines a rung above it. Every rung takes one short arm at its own rung for the cost
# reading, then its own gates; rung 8's gate is the conservation soak, so nobody blocks on this.
# EXIT 0 every rung is green · 1 a rung is red · 2 a rung's run or gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_godot.sh"

PLAYABLE="$ROOT/docs/PLAYABLE_RUNG"
FRAMES="${LA_LADDER_FRAMES:-8}"
GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "ERROR: godot not on PATH — a gate that cannot run FAILS." >&2; exit 2; }

# THE RUNGS AND THEIR GATES, read out of LAProcessSet so this script keeps no second copy of the table.
PROBE_REL="addons/local_agents/tests/zz_ladder_list.gd"
PROBE="$ROOT/$PROBE_REL"
trap 'rm -f "$PROBE" "$PROBE.uid"' EXIT INT TERM
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
  echo
  echo "=== rung $n $name ==="
  t0=$(date +%s)
  arm="$(la_rung_report "$n" "$FRAMES" "step_ms,field_ms,transport_levels")"
  arm_rc=$?
  t1=$(date +%s)
  wall=$((t1 - t0))
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
    bash "$ROOT/scripts/$g"
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

# THE RATCHET. The rung the demo world runs at only rises; a lower finding is reported, never written.
if [ "$green" -ge 0 ] && [ -f "$PLAYABLE" ]; then
  cur="$(grep -v '^#' "$PLAYABLE" | grep -E '^[0-9]+$' | head -1)"
  if [ -n "$cur" ] && [ "$green" -gt "$cur" ]; then
    tmp="$(mktemp)"
    grep '^#' "$PLAYABLE" > "$tmp"
    printf '%s\n' "$green" >> "$tmp"
    mv "$tmp" "$PLAYABLE"
    echo "docs/PLAYABLE_RUNG raised to \"$green_name\"."
  elif [ -n "$cur" ] && [ "$green" -lt "$cur" ]; then
    echo "docs/PLAYABLE_RUNG stands above the highest green rung. The demo world declares more physics"
    echo "than the ladder can prove; lowering it is the maintainer's call, so nothing was written."
  fi
fi
exit "$rc_out"
