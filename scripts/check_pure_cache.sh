#!/usr/bin/env bash
# A STORED ANSWER IS THE SOLVED ANSWER: what a pure native function reads off disk equals its solve, bit for bit.
#   A empty store: solved and written, nothing read   B the store A left: all read, A's values
#   C the stored seed changed: the read shows it      D constants file edited: the address moves
# EXIT 0 the store serves the solved answers · 1 it does not · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_require.sh"
require_tool python3

CONSTANTS="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
[ -f "$CONSTANTS" ] || { echo "check_pure_cache: MISSING ${CONSTANTS#"$ROOT"/}" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_pure_cache.XXXXXX")" || {
	echo "check_pure_cache: no writable temp directory." >&2; exit 2; }
cp "$CONSTANTS" "$WORK/constants.orig" || { echo "check_pure_cache: cannot copy the constants." >&2; exit 2; }
restore() { cp "$WORK/constants.orig" "$CONSTANTS"; rm -rf "$WORK"; }
trap restore EXIT

probe() {  # probe <mode> <out>
	LA_CPU_VALIDATION=1 LA_GODOT_TIMEOUT=120 la_godot --headless --path "$ROOT" \
		-s "res://scripts/pure_cache_probe.gd" -- "$1" > "$WORK/$2.log" 2>&1
}

probe --clear clear || { echo "check_pure_cache: the store could not be cleared." >&2
	tail -5 "$WORK/clear.log" >&2; exit 2; }
probe --read a || { echo "check_pure_cache: arm A did not report." >&2; tail -5 "$WORK/a.log" >&2; exit 2; }
probe --read b || { echo "check_pure_cache: arm B did not report." >&2; tail -5 "$WORK/b.log" >&2; exit 2; }
probe --corrupt corrupt || { echo "check_pure_cache: the stored seed could not be changed," >&2
	echo "                  so this gate has no positive control and its silence proves nothing." >&2
	tail -5 "$WORK/corrupt.log" >&2; exit 2; }
probe --read c || { echo "check_pure_cache: arm C did not report." >&2; tail -5 "$WORK/c.log" >&2; exit 2; }
printf '\n' >> "$CONSTANTS"
probe --read d || { echo "check_pure_cache: arm D did not report." >&2; tail -5 "$WORK/d.log" >&2; exit 2; }
cp "$WORK/constants.orig" "$CONSTANTS"
probe --clear clear2 || true

python3 - "$WORK" <<'PY'
import json, os, struct, sys

work = sys.argv[1]

def arm(name):
	for line in open(os.path.join(work, name + ".log"), errors="replace"):
		if line.startswith("PURE_PROBE="):
			return json.loads(line[len("PURE_PROBE="):])
	print("check_pure_cache: arm %s printed no PURE_PROBE line." % name, file=sys.stderr)
	sys.exit(2)

def values(r):
	raw = bytes.fromhex(r["values"])
	return struct.unpack("<%dd" % (len(raw) // 8), raw)

a, b, c, d = arm("a"), arm("b"), arm("c"), arm("d")
fail = False
if a["hits"] != 0:
	print("FAIL  arm A read %d answer(s) off an emptied store, so A did not solve them." % a["hits"], file=sys.stderr)
	fail = True
if b["hits"] < 3:
	print("FAIL  arm B read %d answer(s) off disk; the seed, the moon's radius and the profile are three."
		% b["hits"], file=sys.stderr)
	fail = True
if b["values"] != a["values"]:
	print("FAIL  what was read is not what was solved.", file=sys.stderr)
	print("      solved %r" % (values(a),), file=sys.stderr)
	print("      read   %r" % (values(b),), file=sys.stderr)
	fail = True
if c["values"] == a["values"]:
	print("FAIL  a changed stored seed did not change what the read returned, so this gate cannot see a",
		file=sys.stderr)
	print("      stored answer that is not the solved one.", file=sys.stderr)
	fail = True
if d["hits"] != 0:
	print("FAIL  an edited constants file still read %d answer(s) off disk: the address does not cover it."
		% d["hits"], file=sys.stderr)
	fail = True
if d["values"] != a["values"]:
	print("FAIL  re-solving under an unchanged constant moved a value.", file=sys.stderr)
	fail = True
if fail:
	sys.exit(1)
print("check_pure_cache: OK (%d values read bit for bit, a changed answer is seen, an edited constants "
	"file moves the address)" % a["n"])
PY
