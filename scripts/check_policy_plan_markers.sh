#!/usr/bin/env bash
# Advisory-only drift check for the kept engineering invariants.
#
# History: this script used to hard-fail (exit 1) unless ~40 exact marker strings
# were present across AGENTS.md / GODOT_BEST_PRACTICES.md / ARCHITECTURE_PLAN.md,
# including wave IDs and a shim inventory with mandatory field counts. That process
# ceremony has been retired. The *engineering* ethos (native/GPU-first, zero
# fallback, fail-fast typed errors, shader-first) is kept as governance prose, so
# this check now merely surfaces drift as ADVISORY warnings and never gates.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AGENTS_FILE="$REPO_ROOT/AGENTS.md"
BEST_PRACTICES_FILE="$REPO_ROOT/GODOT_BEST_PRACTICES.md"

advisories=0

advise_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if [[ ! -f "$file" ]]; then
    echo "ADVISORY: missing file ${file#$REPO_ROOT/} (expected for [$label])"
    advisories=$((advisories + 1))
    return
  fi
  if ! rg -n --no-heading -e "$pattern" "$file" >/dev/null; then
    echo "ADVISORY: [$label] no longer present in ${file#$REPO_ROOT/}"
    advisories=$((advisories + 1))
  fi
}

# Kept engineering invariants — advisory drift signal only.
advise_pattern "$AGENTS_FILE" "Shader-first execution mandate" "agents-shader-first"
advise_pattern "$AGENTS_FILE" "GPU_REQUIRED" "agents-gpu-required"
advise_pattern "$AGENTS_FILE" "NATIVE_REQUIRED" "agents-native-required"

advise_pattern "$BEST_PRACTICES_FILE" "Shader-first execution mandate" "bestpractices-shader-first"
advise_pattern "$BEST_PRACTICES_FILE" "INV-NATIVE-001" "bestpractices-inv-native"
advise_pattern "$BEST_PRACTICES_FILE" "INV-GPU-001" "bestpractices-inv-gpu"
advise_pattern "$BEST_PRACTICES_FILE" "INV-FALLBACK-001" "bestpractices-inv-fallback"
advise_pattern "$BEST_PRACTICES_FILE" "INV-CONTRACT-001" "bestpractices-inv-contract"
advise_pattern "$BEST_PRACTICES_FILE" "INV-HANDSHAKE-001" "bestpractices-inv-handshake"

if [[ "$advisories" -gt 0 ]]; then
  echo
  echo "Policy/plan marker check: $advisories advisory note(s) above (advisory only, does not gate)."
else
  echo "Policy/plan marker check passed (advisory)."
fi
exit 0
