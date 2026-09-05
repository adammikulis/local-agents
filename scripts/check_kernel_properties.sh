#!/usr/bin/env bash
# EVERY KERNEL, ONE PROPERTY AT A TIME, over randomised inputs from a counter-based generator, run on the
# native device with no Godot anywhere. Arm 1 runs the properties; arm 2 plants a defect in a scratch copy
# of a kernel, compiles it with lakc and demands the property that covers it comes back red.
# EXIT 0 clean * 1 a property that held stopped holding, or a planted defect went unnoticed * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_godot_lock.sh"
require_tool cmake

NATIVE="$ROOT/addons/local_agents/native"
KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
LASIM="$NATIVE/bin/lasim"
LAKC="$NATIVE/bin/lakc"
DERIVE="$KERNELS/state_derive.glsl"
PROPS_CPP="$NATIVE/src/tests/PropDerive.cpp"
CEIL_FILE="$ROOT/docs/KERNEL_PROPERTY_CEILING"
# Fixed, so the gate reproduces; a wider sweep is a soak with its own seed.
SEED=20260904

[ -x "$NATIVE/build.sh" ] || { echo "check_kernel_properties: MISSING native/build.sh" >&2; exit 2; }
[ -f "$CEIL_FILE" ] || { echo "check_kernel_properties: no docs/KERNEL_PROPERTY_CEILING." >&2; exit 2; }
CEIL="$(grep -E '^[0-9]+$' "$CEIL_FILE" | head -1)"
case "$CEIL" in "" | *[!0-9]*) echo "check_kernel_properties: the ceiling carries no number." >&2; exit 2 ;; esac

if ! "$NATIVE/build.sh" >/tmp/check_kernel_properties_build.$$ 2>&1; then
	echo "check_kernel_properties: the native build failed; lasim could not be produced." >&2
	tail -30 /tmp/check_kernel_properties_build.$$ >&2
	rm -f /tmp/check_kernel_properties_build.$$
	exit 2
fi
rm -f /tmp/check_kernel_properties_build.$$
[ -x "$LASIM" ] || { echo "check_kernel_properties: the build produced no $LASIM" >&2; exit 2; }
[ -x "$LAKC" ] || { echo "check_kernel_properties: the build produced no $LAKC" >&2; exit 2; }

# The substance-table offsets the derive property writes are the kernel's own. One declaration, held
# to the other by name.
prop_drift=0
for pair in "PROP_STRIDE:kPropStride" "PROP_M:kPropM" "PROP_C:kPropC" \
		"PROP_MOL_PER_KG:kPropMolPerKg" "PROP_ENTRY:kPropEntry" "PROP_LAMBDA:kPropLambda" \
		"PROP_FULL:kPropFull" "PROP_ALPHA:kPropAlpha" "PROP_BULK:kPropBulk" "PROP_TREF:kPropTref" \
		"PROP_LITHIC:kPropLithic" "PROP_RAD_GROUP:kPropRadGroup" "PROP_CONDENSED:kPropCondensed"; do
	g="${pair%%:*}"
	c="${pair##*:}"
	gv="$(sed -n "s/^const int ${g} = \([0-9]*\);.*/\1/p" "$DERIVE" | head -1)"
	cv="$(sed -n "s/^constexpr uint32_t ${c} = \([0-9]*\);.*/\1/p" "$PROPS_CPP" | head -1)"
	if [ -z "$gv" ] || [ -z "$cv" ] || [ "$gv" != "$cv" ]; then
		echo "check_kernel_properties: $g is $gv in state_derive.glsl and $c is $cv in PropDerive.cpp." >&2
		prop_drift=1
	fi
done
[ "$prop_drift" -eq 0 ] || exit 1

# ONE SIM AT A TIME: lasim makes a device on the same GPU every other arm on this machine wants.
la_gpu_lock
lock_rc=$?
[ "$lock_rc" -eq 1 ] && { echo "check_kernel_properties: the GPU lock did not come free." >&2; exit 2; }
cleanup() {
	[ "$lock_rc" -eq 0 ] && la_gpu_unlock
	[ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
}
trap cleanup EXIT

out="$("$LASIM" --property-tests --seed "$SEED" 2>&1)"
printf '%s\n' "$out" | grep -E '^NATIVE_PROPERT|property-tests:'
printf '%s\n' "$out" | grep -q '^NATIVE_PROPERTY=' || {
	echo "check_kernel_properties: the run asserted no property." >&2
	printf '%s\n' "$out" | tail -20 >&2
	exit 2
}

# EVERY KERNEL, NOT MOST OF THEM: a kernel added with no property of its own is a kernel nothing
# asserts anything about, and no ceiling covers that either.
missing=""
for k in "$KERNELS"/*.glsl; do
	name="$(basename "$k")"
	printf '%s\n' "$out" | grep -q "\"kernel\":\"$name\"" || missing="$missing $name"
done
if [ -n "$missing" ]; then
	echo "check_kernel_properties: no property asserts anything about:$missing" >&2
	exit 1
fi

# A property that passes with its own reference shifted asserts nothing, and no ceiling covers that.
vacuous="$(printf '%s\n' "$out" | grep -c '"control_red":false' || true)"
if [ "$vacuous" -gt 0 ]; then
	echo "check_kernel_properties: $vacuous propert(y|ies) held with the reference shifted." >&2
	printf '%s\n' "$out" | grep '"control_red":false' >&2
	exit 1
fi

red="$(printf '%s\n' "$out" | grep -c '"held":false' || true)"
echo "KERNEL_PROPERTIES={\"red\":$red,\"cap\":$CEIL}"
if [ "$red" -gt "$CEIL" ]; then
	echo "check_kernel_properties: $red propert(y|ies) do not hold, ceiling $CEIL." >&2
	printf '%s\n' "$out" | grep '"held":false' >&2
	exit 1
fi
if [ "$red" -lt "$CEIL" ]; then
	ceiling_slack "KERNEL_PROPERTY_CEILING" "$red" "$CEIL" 2>/dev/null \
		|| echo "NOTE  $((CEIL - red)) below the ceiling — the integrator banks it."
fi

# --- arm 2: a defect planted in the kernel itself must be caught -------------------------------------
SCRATCH="$(mktemp -d)"
plant() {  # plant <file> <sed expr> <property that must go red>
	rm -f "$SCRATCH"/*.glsl "$SCRATCH"/*.glsli "$SCRATCH"/kernels.blob
	cp "$KERNELS"/*.glsl "$KERNELS"/*.glsli "$SCRATCH/"
	sed -i '' -e "$2" "$SCRATCH/$1" 2>/dev/null || sed -i -e "$2" "$SCRATCH/$1"
	if cmp -s "$KERNELS/$1" "$SCRATCH/$1"; then
		echo "check_kernel_properties: the mutation did not change $1, so it plants nothing." >&2
		exit 2
	fi
	if ! "$LAKC" --kernels "$SCRATCH" --out "$SCRATCH/kernels.blob" >/dev/null 2>&1; then
		echo "check_kernel_properties: the mutated $1 did not compile, so the arm proves nothing." >&2
		exit 2
	fi
	local mout
	mout="$("$LASIM" --kernels "$SCRATCH/kernels.blob" --property-tests --seed "$SEED" --only "$3" 2>&1)"
	if printf '%s\n' "$mout" | grep -q "\"name\":\"$3\",\"held\":true"; then
		echo "check_kernel_properties: $3 still held with a defect planted in $1." >&2
		exit 1
	fi
	printf '%s\n' "$mout" | grep -q "\"name\":\"$3\"" || {
		echo "check_kernel_properties: $3 did not run against the mutated $1." >&2
		printf '%s\n' "$mout" | tail -10 >&2
		exit 2
	}
	echo "  planted in $1 -> $3 red"
}

plant "pressure.glsl" 's|acc += la_load(uint(a));|acc += 1.5 * la_load(uint(a));|' \
	"pressure_column_is_the_integral_of_rho_g"
plant "flux.glsl" 's|float open = min(open_c, 1.0 - clamp(resist\[n\], 0.0, 1.0));|float open = open_c;|' \
	"flux_crossings_are_antisymmetric"

echo "check_kernel_properties: OK ($red against a ceiling of $CEIL; planted defects come back red)"
