#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_require.sh
source "$SCRIPT_DIR/lib_require.sh"
require_tool rg   # the search below is `|| true`, so a missing rg would silently report "passed"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# RefCounted test modules under addons/local_agents/tests/test_*.gd must run
# through run_single_test.gd, never as direct SceneTree scripts.
pattern='godot[[:space:]]+--headless[[:space:]]+--no-window[[:space:]]+-s[[:space:]]+(res://)?addons/local_agents/tests/test_[^[:space:]]+\.gd([[:space:]]|$)'

SCAN_ROOTS=(addons/local_agents scripts .github)

# Prove the search had something to search BEFORE trusting an empty result. The hit search below ends in
# `|| true` and swallows stderr, so a renamed or missing root contributes no hits and the gate prints
# "passed" — the pass condition here is the ABSENCE of a pattern, and absence from a directory that was
# never read is not evidence.
#
# The check is per-ROOT, not a total file count, because a total can never reach zero here: this gate
# lives in scripts/, which is one of its own scan roots, so it would always find at least itself and a
# count-based guard could never fire. Losing addons/local_agents while scripts/ survives is the failure
# that actually happens, and only a per-root check sees it.
for root in "${SCAN_ROOTS[@]}"; do
  if [[ ! -d "$REPO_ROOT/$root" ]]; then
    echo "ERROR: check_no_direct_refcounted_invocation.sh scan root '$root' does not exist." >&2
    echo "       It moved or was renamed and this gate stopped covering it silently." >&2
    echo "       Update SCAN_ROOTS; do not leave an entry that searches nothing." >&2
    exit 2
  fi
done
scanned="$(
  cd "$REPO_ROOT"
  rg --files "${SCAN_ROOTS[@]}" \
    --glob '*.sh' --glob '*.yml' --glob '*.yaml' --glob 'Makefile' 2>/dev/null | grep -c . || true
)"

# A root-level Makefile is searched only when there is one. This used to be an unconditional `Makefile`
# argument, and there has never been a Makefile in this repo, so rg failed on it on every single run —
# invisibly, because the search redirects stderr and ends in `|| true`. Harmless here, but it is the same
# habit as the rest of this file's history: a scan target that does not exist, silently skipped.
TARGETS=("${SCAN_ROOTS[@]}")
[[ -f "$REPO_ROOT/Makefile" ]] && TARGETS+=(Makefile)

violations="$(
  cd "$REPO_ROOT"
  rg -n --no-heading --pcre2 "$pattern" \
    --glob '*.sh' \
    --glob '*.yml' \
    --glob '*.yaml' \
    --glob 'Makefile' \
    --glob '.github/workflows/*' \
    "${TARGETS[@]}" 2>/dev/null || true
)"

if [[ -n "$violations" ]]; then
  echo "Direct RefCounted test invocation is banned. Found:"
  echo "$violations"
  echo
  echo "Remediation:"
  echo "1) Use scripts/run_single_test.sh <test_*.gd> [--timeout=<seconds>]."
  echo "2) Or use the wrapper directly:"
  echo "   godot --headless --no-window -s addons/local_agents/tests/run_single_test.gd -- --test=res://addons/local_agents/tests/test_<name>.gd --timeout=120"
  exit 1
fi

echo "Direct RefCounted invocation check passed ($scanned files searched)."
