#!/usr/bin/env bash
# glslang and SPIRV-Cross: the two host libraries lakc compiles kernels with. Pinned by FULL sha --
# `git fetch origin <short-sha>` reads a short sha as a ref name and fails.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NATIVE_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
THIRDPARTY_DIR="${NATIVE_DIR}/thirdparty"

GLSLANG_REPO="https://github.com/KhronosGroup/glslang.git"
SPIRV_CROSS_REPO="https://github.com/KhronosGroup/SPIRV-Cross.git"
GLSLANG_REF="${GLSLANG_REF:-168d452a4f460d24b588fed08477a81c44ee27a1}"
SPIRV_CROSS_REF="${SPIRV_CROSS_REF:-6c09849fe88c48eaed08413aa022aaa136a3a057}"

usage() {
	cat <<USAGE
Usage: $(basename "$0") [--clean] [--print-refs]
Environment: GLSLANG_REF (${GLSLANG_REF}), SPIRV_CROSS_REF (${SPIRV_CROSS_REF}).
USAGE
}

clone_if_missing() {
	local url="$1" dest="$2"
	if [ -d "$dest/.git" ]; then
		echo "[skip] $(basename "$dest") already cloned"
	else
		echo "[git] cloning $url"
		git clone --filter=blob:none --no-checkout "$url" "$dest"
	fi
}

sync_repo_ref() {
	local dest="$1" ref="$2"
	if [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo none)" = "$ref" ]; then
		echo "[skip] $(basename "$dest") already at $ref"
		return
	fi
	echo "[git] syncing $(basename "$dest") to $ref"
	git -C "$dest" fetch --depth 1 origin "$ref" || git -C "$dest" fetch origin "$ref"
	git -C "$dest" checkout --detach FETCH_HEAD
}

while [ $# -gt 0 ]; do
	case "$1" in
		--clean) rm -rf "$THIRDPARTY_DIR"; exit 0 ;;
		--print-refs) printf '%s\n%s\n' "$GLSLANG_REF" "$SPIRV_CROSS_REF"; exit 0 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

for bin in git cmake; do
	command -v "$bin" >/dev/null 2>&1 || { echo "Error: '$bin' is not in PATH" >&2; exit 1; }
done

mkdir -p "$THIRDPARTY_DIR"
clone_if_missing "$GLSLANG_REPO" "$THIRDPARTY_DIR/glslang"
clone_if_missing "$SPIRV_CROSS_REPO" "$THIRDPARTY_DIR/SPIRV-Cross"
sync_repo_ref "$THIRDPARTY_DIR/glslang" "$GLSLANG_REF"
sync_repo_ref "$THIRDPARTY_DIR/SPIRV-Cross" "$SPIRV_CROSS_REF"
echo "Native dependencies fetched into ${THIRDPARTY_DIR}."
