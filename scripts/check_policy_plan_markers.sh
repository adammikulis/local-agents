#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AGENTS_FILE="$REPO_ROOT/AGENTS.md"
BEST_PRACTICES_FILE="$REPO_ROOT/GODOT_BEST_PRACTICES.md"
PLAN_FILE="$REPO_ROOT/ARCHITECTURE_PLAN.md"

errors=0

require_pattern() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if ! rg -n --no-heading -e "$pattern" "$file" >/dev/null; then
    echo "MISSING [$label] in ${file#$REPO_ROOT/}"
    errors=$((errors + 1))
  fi
}

require_min_count() {
  local file="$1"
  local pattern="$2"
  local min_count="$3"
  local label="$4"
  local count
  count=$(rg -n --no-heading -e "$pattern" "$file" | wc -l | tr -d '[:space:]')
  if [[ "$count" -lt "$min_count" ]]; then
    echo "INSUFFICIENT [$label] in ${file#$REPO_ROOT/}: found $count, need >= $min_count"
    errors=$((errors + 1))
  fi
}

for file in "$AGENTS_FILE" "$BEST_PRACTICES_FILE" "$PLAN_FILE"; do
  if [[ ! -f "$file" ]]; then
    echo "REQUIRED FILE MISSING: ${file#$REPO_ROOT/}"
    errors=$((errors + 1))
  fi
done

# AGENTS policy markers
require_pattern "$AGENTS_FILE" 'Read `GODOT_BEST_PRACTICES.md` at session startup' "agents-startup-reading"
require_pattern "$AGENTS_FILE" "Validation order default is mandatory" "agents-validation-order"
require_pattern "$AGENTS_FILE" "Shader-first execution mandate" "agents-shader-first"
require_pattern "$AGENTS_FILE" "GPU_REQUIRED" "agents-gpu-required"
require_pattern "$AGENTS_FILE" "NATIVE_REQUIRED" "agents-native-required"
require_pattern "$AGENTS_FILE" "Transitional shim tracking mandate" "agents-shim-tracking"
require_pattern "$AGENTS_FILE" "Strict transitional tracking for remaining CPU/GDS pieces" "agents-shim-blocker-tracking"

# Godot best-practices markers
require_pattern "$BEST_PRACTICES_FILE" "Shader-first execution mandate" "bestpractices-shader-first"
require_pattern "$BEST_PRACTICES_FILE" "Strict transitional tracking for remaining CPU/GDS pieces" "bestpractices-shim-tracking"
require_pattern "$BEST_PRACTICES_FILE" 'Any "works"/"ready" claim requires both evidence classes on the current tree' "bestpractices-validation-order"
require_pattern "$BEST_PRACTICES_FILE" "INV-NATIVE-001" "bestpractices-inv-native"
require_pattern "$BEST_PRACTICES_FILE" "INV-GPU-001" "bestpractices-inv-gpu"
require_pattern "$BEST_PRACTICES_FILE" "INV-FALLBACK-001" "bestpractices-inv-fallback"
require_pattern "$BEST_PRACTICES_FILE" "INV-CONTRACT-001" "bestpractices-inv-contract"
require_pattern "$BEST_PRACTICES_FILE" "INV-HANDSHAKE-001" "bestpractices-inv-handshake"
require_pattern "$BEST_PRACTICES_FILE" "INV-PROJECTILE-DIRECT-001" "bestpractices-inv-projectile-direct"
require_pattern "$BEST_PRACTICES_FILE" "INV-NO-GDS-MULTIHOP-001" "bestpractices-inv-no-gds-multihop"

# Architecture plan enforceable wave + shim markers
require_pattern "$PLAN_FILE" "WF-P0-SHADER-VOXEL-DESTRUCTION-2026-02-17" "plan-wave-id"
require_pattern "$PLAN_FILE" "Priority: .*P0" "plan-wave-priority"
require_pattern "$PLAN_FILE" "Owners:" "plan-wave-owners"
require_pattern "$PLAN_FILE" "Acceptance criteria:" "plan-wave-acceptance"
require_pattern "$PLAN_FILE" "Verification commands \(run in order\):" "plan-wave-verification"
require_pattern "$PLAN_FILE" "Wave invariants:" "plan-wave-invariants"
require_pattern "$PLAN_FILE" "Transitional shim inventory \(required fields\):" "plan-shim-inventory"
require_pattern "$PLAN_FILE" "owner:" "plan-shim-owner-field"
require_pattern "$PLAN_FILE" "removal trigger:" "plan-shim-removal-trigger-field"
require_pattern "$PLAN_FILE" "target wave:" "plan-shim-target-wave-field"
require_pattern "$PLAN_FILE" "blocker:" "plan-shim-blocker-field"
require_pattern "$PLAN_FILE" "INV-NATIVE-001" "plan-inv-native"
require_pattern "$PLAN_FILE" "INV-GPU-001" "plan-inv-gpu"
require_pattern "$PLAN_FILE" "INV-FALLBACK-001" "plan-inv-fallback"
require_pattern "$PLAN_FILE" "INV-CONTRACT-001" "plan-inv-contract"
require_pattern "$PLAN_FILE" "INV-HANDSHAKE-001" "plan-inv-handshake"
require_pattern "$PLAN_FILE" "INV-PROJECTILE-DIRECT-001" "plan-inv-projectile-direct"
require_pattern "$PLAN_FILE" "INV-NO-GDS-MULTIHOP-001" "plan-inv-no-gds-multihop"

require_min_count "$PLAN_FILE" "^\s*-\s+owner:" 3 "plan-shim-owner-count"
require_min_count "$PLAN_FILE" "^\s*-\s+removal trigger:" 3 "plan-shim-removal-trigger-count"
require_min_count "$PLAN_FILE" "^\s*-\s+target wave:" 3 "plan-shim-target-wave-count"
require_min_count "$PLAN_FILE" "^\s*-\s+blocker:" 3 "plan-shim-blocker-count"

if [[ "$errors" -gt 0 ]]; then
  echo
  echo "Policy/plan marker check failed with $errors issue(s)."
  exit 1
fi

echo "Policy/plan marker check passed."
