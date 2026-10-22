#!/usr/bin/env bash
# THE NATIVE TOOLS, BUILT ONCE PER CONTENT AND SHARED BY EVERY TREE AND EVERY GATE THAT NEEDS THEM.
#   la_native_build [--target lakc]   leaves lakc, lasim and kernels.blob in native/bin. 0 ready * 2 not.
# lakc and lasim are a function of the native sources, the headers lasim includes, the kernel #include
# files it compiles as C++ and the dependency key. A tree with no build of its own whose inputs match an
# entry copies the pair, and lakc bakes the blob off THIS tree's kernels. Only a full build fills an entry.

LA_NB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LA_NB_DIR="$LA_NB_ROOT/addons/local_agents/native"
LA_NB_KERNELS="$LA_NB_ROOT/addons/local_agents/sim/material/kernels3d"
LA_NB_CACHE="${LA_NATIVE_BIN_CACHE:-$HOME/.cache/local-agents/nativebin}"
LA_NB_KEEP=8

# One hex digest of everything the pair is compiled from, or nothing.
la_native_key() {
	local deps
	deps="$("$LA_NB_DIR/build.sh" --print-deps-key 2>/dev/null)" || return 1
	[ -n "$deps" ] || return 1
	python3 - "$LA_NB_ROOT" "$deps" <<'PY'
import hashlib, os, sys

root, deps = sys.argv[1], sys.argv[2]
native = os.path.join(root, "addons/local_agents/native")
skip = {"bin", "build", "thirdparty", "__pycache__"}
paths = []
for top, dirs, files in os.walk(native):
    dirs[:] = sorted(d for d in dirs if d not in skip)
    paths += [os.path.join(top, f) for f in sorted(files)]
for sub, suffixes in (("addons/local_agents/gdextensions/localagents/include", (".hpp", ".h")),
                      ("addons/local_agents/sim/material/kernels3d", (".glsli",))):
    base = os.path.join(root, sub)
    if os.path.isdir(base):
        paths += [os.path.join(base, f) for f in sorted(os.listdir(base)) if f.endswith(suffixes)]
h = hashlib.md5(deps.encode())
for p in paths:
    h.update(b"\0" + os.path.relpath(p, root).encode() + b"\0")
    with open(p, "rb") as fh:
        h.update(fh.read())
print(h.hexdigest())
PY
}

# The blob lakc bakes off this tree's kernels: what native/CMakeLists.txt's custom command runs.
la_native_bake() {
	"$LA_NB_DIR/bin/lakc" --kernels "$LA_NB_KERNELS" --out "$LA_NB_DIR/bin/kernels.blob"
}

la_native_build() {
	local target="" key="" entry="" log tmp
	[ "${1:-}" = "--target" ] && target="$2"
	key="$(la_native_key)" || key=""
	[ -n "$key" ] && entry="$LA_NB_CACHE/$key"
	[ -f "$entry/COMPLETE" ] && touch "$entry"
	# A tree that has built before holds its own incremental state, which is the authority; one that has
	# not copies the pair.
	if [ -n "$entry" ] && [ -f "$entry/COMPLETE" ] && [ ! -f "$LA_NB_DIR/build/CMakeCache.txt" ]; then
		mkdir -p "$LA_NB_DIR/bin"
		cp -p "$entry/lakc" "$entry/lasim" "$LA_NB_DIR/bin/" || return 2
		if [ "$target" != "lakc" ] && ! la_native_bake >/dev/null 2>&1; then
			echo "lib_native_build: lakc did not bake the kernels." >&2
			return 2
		fi
		return 0
	fi
	log="$(mktemp "${TMPDIR:-/tmp}/la_native_build.XXXXXX")"
	"$LA_NB_DIR/build.sh" ${target:+--target "$target"} >"$log" 2>&1 || {
		tail -30 "$log" >&2
		rm -f "$log"
		return 2
	}
	rm -f "$log"
	if [ -z "$target" ] && [ -n "$entry" ] && [ ! -f "$entry/COMPLETE" ] \
			&& [ -x "$LA_NB_DIR/bin/lakc" ] && [ -x "$LA_NB_DIR/bin/lasim" ]; then
		tmp="$entry.tmp.$$"
		rm -rf "$tmp"
		mkdir -p "$tmp" && cp -p "$LA_NB_DIR/bin/lakc" "$LA_NB_DIR/bin/lasim" "$tmp/" && : > "$tmp/COMPLETE" \
			&& mv "$tmp" "$entry" 2>/dev/null
		rm -rf "$tmp"
		ls -dt "$LA_NB_CACHE"/*/ 2>/dev/null | grep -v '\.tmp\.' | tail -n +$((LA_NB_KEEP + 1)) | while IFS= read -r old; do
			rm -rf "$old"
		done
	fi
	return 0
}
