#!/usr/bin/env bash
# THE COMPUTE DEVICE THE PHYSICS WILL RUN ON, WITH NO GODOT ANYWHERE. Arm 1 is the device's own mechanics;
# arm 2 builds a pipeline for every kernel and dispatches the two probe kernels. Arm 3 corrupts the baked
# blob, because a device that accepts a damaged blob is a device that runs half a pipeline in silence.
# EXIT 0 clean * 1 a selftest failed, or a corrupt blob was accepted * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_godot_lock.sh"
require_tool cmake

NATIVE="$ROOT/addons/local_agents/native"
LASIM="$NATIVE/bin/lasim"
BLOB="$NATIVE/bin/kernels.blob"
[ -x "$NATIVE/build.sh" ] || { echo "check_native_device: MISSING native/build.sh" >&2; exit 2; }

if ! "$NATIVE/build.sh" >/tmp/check_native_build.$$ 2>&1; then
	echo "check_native_device: the native build failed; lasim could not be produced." >&2
	tail -30 /tmp/check_native_build.$$ >&2
	rm -f /tmp/check_native_build.$$
	exit 2
fi
rm -f /tmp/check_native_build.$$
[ -x "$LASIM" ] || { echo "check_native_device: the build produced no $LASIM" >&2; exit 2; }
[ -f "$BLOB" ] || { echo "check_native_device: the build produced no $BLOB" >&2; exit 2; }

# ONE SIM AT A TIME: lasim makes a device on the same GPU every other arm on this machine wants.
la_gpu_lock
lock_rc=$?
[ "$lock_rc" -eq 1 ] && { echo "check_native_device: the GPU lock did not come free." >&2; exit 2; }

run_arm() {
	local arm="$1" out rc
	out="$("$LASIM" "$arm" 2>&1)"
	rc=$?
	printf '%s\n' "$out"
	if [ "$rc" -ne 0 ]; then
		echo "check_native_device: $arm exited $rc." >&2
		exit "$rc"
	fi
}

run_arm --selftest-device
run_arm --selftest-kernels

# The mutation. One byte of the payload flipped must be refused, not read as a pipeline.
SCRATCH="$(mktemp -d)"
cleanup() {
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
	rm -rf "$SCRATCH"
}
trap cleanup EXIT
cp "$BLOB" "$SCRATCH/kernels.blob"
size="$(wc -c < "$SCRATCH/kernels.blob" | tr -d '[:space:]')"
printf '\xff' | dd of="$SCRATCH/kernels.blob" bs=1 seek="$(( size / 2 ))" count=1 conv=notrunc \
	status=none
if "$LASIM" --kernels "$SCRATCH/kernels.blob" --selftest-device >/dev/null 2>&1; then
	echo "check_native_device: a corrupted kernel blob was loaded and dispatched from." >&2
	exit 1
fi
echo "check_native_device: OK (both selftests green; a corrupted blob is refused)"
