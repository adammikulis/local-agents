#!/usr/bin/env bash
# THE BAKE STORE HOLDS TO ITS DECLARED BOUND: save_into removes the least recently used entries, a hit counts
# as use, the entry just written stays. The probe runs it on a scratch directory, never on the real store.
#   six entries under a bound of four and a half · a bound of one byte · docs/FIELD_CACHE_BYTES is the one read
# EXIT 0 the store is held to its bound · 1 it is not · 2 could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_require.sh"
require_tool python3

DECLARED="$ROOT/docs/FIELD_CACHE_BYTES"
[ -f "$DECLARED" ] || { echo "check_field_cache_eviction: MISSING docs/FIELD_CACHE_BYTES" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_evict.XXXXXX")" || {
	echo "check_field_cache_eviction: no writable temp directory." >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

LA_CPU_VALIDATION=1 LA_GODOT_TIMEOUT=120 la_godot --headless --path "$ROOT" \
	-s "res://scripts/field_cache_evict_probe.gd" > "$WORK/probe.log" 2>&1 || {
	echo "check_field_cache_eviction: the probe did not run." >&2; tail -5 "$WORK/probe.log" >&2; exit 2; }

python3 - "$WORK/probe.log" "$DECLARED" <<'PY'
import json, sys

lines = [l for l in open(sys.argv[1], errors="replace") if l.startswith("EVICT_PROBE=")]
if not lines:
	print("check_field_cache_eviction: the probe printed no EVICT_PROBE line.", file=sys.stderr)
	sys.exit(2)
r = json.loads(lines[-1][len("EVICT_PROBE="):])
declared = [int(l) for l in (x.strip() for x in open(sys.argv[2])) if l.lstrip("-").isdigit()]
fail = False

def say(msg):
	global fail
	print("FAIL  " + msg, file=sys.stderr)
	fail = True

if not r["hit"] or r["entry_bytes"] <= 0:
	say("the probe's own entries were not written and read back, so it measured nothing.")
want = ["k0.bin", "k3.bin", "k4.bin", "k5.bin"]
if r["left"] != want:
	say("six entries under a bound of four and a half left %r; the two oldest untouched go and the entry "
		"read back stays, so %r." % (r["left"], want))
if r["removed"] != 2:
	say("%d entries removed where the bound needed two." % r["removed"])
if r["left_bytes"] > r["bound"]:
	say("the directory holds %d bytes past its bound of %d." % (r["left_bytes"], r["bound"]))
if r["left_floor"] != ["k6.bin"]:
	say("a bound of one byte left %r; only the entry just written may stay." % (r["left_floor"],))
if len(declared) != 1 or declared[0] <= 0 or r["declared"] != declared[0]:
	say("docs/FIELD_CACHE_BYTES declares %r and the extension reads %r." % (declared, r["declared"]))
if fail:
	sys.exit(1)
print("check_field_cache_eviction: OK (held to its bound least recently used first, a hit counts as use, "
	"the entry just written stays, the declared bound is read)")
PY
