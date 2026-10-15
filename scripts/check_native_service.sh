#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot_lock.sh"
. "$ROOT/scripts/lib_lasim.sh"
. "$ROOT/scripts/lib_lasim_oracle.sh"
require_tool python3
require_tool cmake
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_service_gate.XXXXXX")"
lock_result=1
cleanup() {
	la_lasim_oracle_clean
	[ "$lock_result" -ne 0 ] || la_gpu_unlock
	rm -rf "$WORK"
}
trap cleanup EXIT
la_lasim_build || exit 2
la_lasim_oracle_write
la_lasim_oracle_run "$WORK" 1 || exit 2
la_gpu_lock
lock_result=$?
[ "$lock_result" -ne 1 ] || exit 2
python3 "$LA_NATIVE_DIR/src/tests/service_child_test.py" "$LASIM_BIN" "$LASIM_BLOB" || exit 1
python3 "$LA_NATIVE_DIR/src/tests/service_compute_test.py" "$LASIM_BIN" "$LASIM_BLOB" "$WORK" || exit 1
echo 'check_native_service: OK'
