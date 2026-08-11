#!/usr/bin/env bash
# =====================================================================================================
# NO INVISIBLE FALLBACKS. A missing measurement is missing; it may not be replaced by another source.
#
# `legs.get("rock_fill", _f._rock_fill)` reads the probe and, when the probe leg has not arrived, silently
# substitutes the CPU mirror. The mirror's freshness depends on which OTHER consumer last called
# request_channel, so the gauge reads the observer instead of the planet. The fallback is what makes it
# invisible: it hands back something shaped like a measurement.
#
# BANNED: a `.get(key, X)` whose default is another data source — a field, a mirror, a member array.
# ALLOWED: an empty/zero default, which reads as ABSENT and forces the caller to say "unmeasured".
#
# EXIT CODES. 0 none · 1 found · 2 could not run.
# =====================================================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v rg >/dev/null 2>&1 || { echo "ERROR: rg not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents/sim/material" ] || { echo "ERROR: source root missing." >&2; exit 2; }

hits="$(rg -n --type-add 'gd:*.gd' -tgd '\.get\("[a-z_]+",\s*_f\._[a-z_]+\)' \
  "$REPO_ROOT/addons/local_agents/sim/material" 2>/dev/null || true)"
n="$(printf '%s' "$hits" | grep -c . || true)"
echo "SILENT_FALLBACKS={\"count\":$n}"
[ "$n" -eq 0 ] && { echo "check_no_silent_fallback: OK"; exit 0; }
echo "$hits"
echo
echo "A missing measurement is missing. Default to an empty array and refuse the total, naming what did not"
echo "arrive — do not substitute a mirror whose freshness depends on who is watching."
exit 1
