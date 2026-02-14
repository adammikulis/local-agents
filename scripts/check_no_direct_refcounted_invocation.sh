#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# RefCounted test modules under addons/local_agents/tests/test_*.gd must run
# through run_single_test.gd, never as direct SceneTree scripts.
pattern='godot[[:space:]]+--headless[[:space:]]+--no-window[[:space:]]+-s[[:space:]]+(res://)?addons/local_agents/tests/test_[^[:space:]]+\.gd([[:space:]]|$)'

violations="$(
  cd "$REPO_ROOT"
  rg -n --no-heading --pcre2 "$pattern" \
    --glob '*.sh' \
    --glob '*.yml' \
    --glob '*.yaml' \
    --glob 'Makefile' \
    --glob '.github/workflows/*' \
    addons/local_agents scripts .github Makefile 2>/dev/null || true
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

echo "Direct RefCounted invocation check passed."
