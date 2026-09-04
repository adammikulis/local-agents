#!/usr/bin/env bash
# A KERNEL THAT DOES NOT COMPILE IS A BUILD FAILURE. lakc compiles every kernel to SPIR-V and then to MSL
# at build time; the second arm breaks a scratch copy on purpose, because a compiler that never says no
# has never been shown to say no.
# EXIT 0 clean * 1 a kernel did not compile, or a broken one did * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool cmake

NATIVE="$ROOT/addons/local_agents/native"
KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
LAKC="$NATIVE/bin/lakc"
[ -d "$KERNELS" ] || { echo "check_lakc: MISSING ${KERNELS#"$ROOT"/}" >&2; exit 2; }
[ -x "$NATIVE/build.sh" ] || { echo "check_lakc: MISSING native/build.sh" >&2; exit 2; }

# The compiler alone. Baking the blob is check_native_device's arm, and building it here would turn a
# kernel that does not compile into a build failure instead of this gate's own verdict.
if ! "$NATIVE/build.sh" --target lakc >/tmp/check_lakc_build.$$ 2>&1; then
	echo "check_lakc: the native build failed; lakc could not be produced." >&2
	tail -30 /tmp/check_lakc_build.$$ >&2
	rm -f /tmp/check_lakc_build.$$
	exit 2
fi
rm -f /tmp/check_lakc_build.$$
[ -x "$LAKC" ] || { echo "check_lakc: the build produced no $LAKC" >&2; exit 2; }

count="$(ls "$KERNELS"/*.glsl 2>/dev/null | wc -l | tr -d '[:space:]')"
require_scanned "$count" 6 "kernels"

if ! out="$("$LAKC" --kernels "$KERNELS" --check 2>&1)"; then
	echo "check_lakc: a kernel did not compile." >&2
	printf '%s\n' "$out" >&2
	exit 1
fi
printf '%s\n' "$out"

# The mutation. A scratch copy with a syntax error in it must come back red, naming the file.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp "$KERNELS"/*.glsl "$KERNELS"/*.glsli "$SCRATCH/"
printf '\nvoid la_lakc_mutation( {\n' >> "$SCRATCH/pressure.glsl"
if mut="$("$LAKC" --kernels "$SCRATCH" --check 2>&1)"; then
	echo "check_lakc: a kernel with a syntax error in it compiled clean. The compiler is not gating." >&2
	exit 1
fi
case "$mut" in
	*pressure.glsl*) ;;
	*) echo "check_lakc: the failure does not name the file it is in:" >&2
	   printf '%s\n' "$mut" >&2
	   exit 1 ;;
esac
echo "check_lakc: OK ($count kernels compile; a broken one is refused, naming pressure.glsl)"
