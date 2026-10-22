#!/usr/bin/env bash
# THE NATIVE SIM PROCESS: `la_lasim_build` (0 built, 2 the build produced nothing) then `la_lasim <args>`.
# lasim makes a compute device on the same GPU every other arm on this machine wants, so the caller holds
# la_gpu_lock (lib_godot_lock.sh) across the calls — and only across them, never across a Godot launch,
# which takes the extension lock first and would deadlock against a lane holding it.

LA_NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../addons/local_agents/native" && pwd)"
LASIM_BIN="$LA_NATIVE_DIR/bin/lasim"
LASIM_BLOB="$LA_NATIVE_DIR/bin/kernels.blob"

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_native_build.sh"

la_lasim_build() {
	if ! la_native_build; then
		echo "lib_lasim: the native build failed; lasim could not be produced." >&2
		return 2
	fi
	[ -x "$LASIM_BIN" ] || { echo "lib_lasim: the build produced no $LASIM_BIN" >&2; return 2; }
	[ -f "$LASIM_BLOB" ] || { echo "lib_lasim: the build produced no $LASIM_BLOB" >&2; return 2; }
	return 0
}

la_lasim() {
	"$LASIM_BIN" "$@"
}
