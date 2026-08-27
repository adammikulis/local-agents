#!/usr/bin/env bash
# A staged binary that names an absolute /opt or /usr/local path is linked against the BUILD MACHINE.
# Exported, it cannot load anywhere that install is missing, and the extension dies with it. Everything
# in bin/ names its siblings by @loader_path / $ORIGIN, or a system path, and nothing else.
#
# EXIT 0 clean · 1 a build-machine path · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/addons/local_agents/gdextensions/localagents/bin"
[ -d "$BIN" ] || { echo "check_bin_relocatable: MISSING $BIN. Build the extension first." >&2; exit 2; }

FOREIGN='^/(opt|usr/local)/'

files="$(find "$BIN" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \
	-o -name 'llama-cli' -o -name 'llama-server' -o -name 'localagents.*' \) 2>/dev/null)"
[ -n "$files" ] || { echo "check_bin_relocatable: no libraries under $BIN. A gate that examines nothing is not a gate." >&2; exit 2; }

if command -v otool >/dev/null 2>&1; then
	inspect() {  # every dependency and every rpath the loader will follow
		otool -L "$1" | tail -n +2 | awk '{print $1}'
		otool -l "$1" | awk '/LC_RPATH/{r=1} r&&/ path /{print $2; r=0}'
	}
elif command -v objdump >/dev/null 2>&1; then
	inspect() {
		objdump -p "$1" 2>/dev/null \
			| awk '$1=="NEEDED"{print $2} $1=="RPATH"||$1=="RUNPATH"{print $2}' | tr ':' '\n'
	}
else
	echo "check_bin_relocatable: neither otool nor objdump is present, so nothing was examined." >&2
	exit 2
fi

fail=0
seen=0
while IFS= read -r f; do
	[ -n "$f" ] || continue
	seen=$((seen + 1))
	hits="$(inspect "$f" | grep -E "$FOREIGN" | sort -u)"
	[ -n "$hits" ] || continue
	while IFS= read -r hit; do
		echo "FAIL  ${f#"$BIN"/} links $hit, a path that exists only on the machine that built it." >&2
	done <<< "$hits"
	fail=1
done <<< "$files"

if [ "$seen" -eq 0 ]; then
	echo "check_bin_relocatable: examined no file. A gate that examines nothing is not a gate." >&2
	exit 2
fi
if [ "$fail" -ne 0 ]; then
	echo "" >&2
	echo "      build_extension.sh vendors these: it copies each one beside the binaries and rewrites the" >&2
	echo "      reference to @loader_path. Rebuild, or add the dependency's own kind to that step." >&2
	exit 1
fi
echo "check_bin_relocatable: OK ($seen binaries, every dependency relocatable)"
