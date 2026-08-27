#!/usr/bin/env bash
# Every shell command README.md prints must still exist and still take the arguments it is shown with.
# SKIP_RUN names the ones that launch an engine; those are checked without launching anything.
# EXIT 0 clean · 1 a command the tree cannot honour · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool rg
DOC="$ROOT/README.md"
[ -f "$DOC" ] || { echo "check_readme_commands: no README.md." >&2; exit 2; }

# Programs whose --help is cheap and side-effect free. Their subcommands and flags are read back off it.
HELP_OK="scripts/agent_harness.sh scripts/run_demo.sh addons/local_agents/gdextensions/localagents/scripts/fetch_dependencies.sh addons/local_agents/gdextensions/localagents/scripts/build_extension.sh"
# Programs that take the machine's GPU lock or the editor lock. Existence only.
SKIP_RUN="scripts/run_sim_offscreen.sh scripts/editor_scan.sh scripts/sim_run.sh"

# Fenced bash blocks, comments stripped, backslash continuations joined, blanks dropped.
CMDS="$(awk '/^```(bash|sh)$/{inb=1;next} /^```/{inb=0} inb' "$DOC" \
	| sed 's/[[:space:]]*#.*$//' \
	| awk '{ if (sub(/\\$/, "")) { printf "%s", $0 } else { print } }' \
	| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | rg -v '^$' || true)"
[ -n "$CMDS" ] || { echo "check_readme_commands: README.md prints no shell command." >&2; exit 2; }

HELPDIR="$(mktemp -d "${TMPDIR:-/tmp}/la_readme_help.XXXXXX")" || exit 2
trap 'rm -rf "$HELPDIR"' EXIT
fail=0
checked=0
say() { echo "FAIL  $1" >&2; fail=1; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

# One --help per program, cached. A non-zero exit is itself the failure.
help_text() {
	local prog="$1" out="$HELPDIR/$(printf '%s' "$1" | tr '/' '_')"
	if [ ! -f "$out" ]; then
		if ! "$ROOT/$prog" --help > "$out" 2>&1; then
			rm -f "$out"
			return 1
		fi
	fi
	printf '%s' "$out"
}

while IFS= read -r cmd; do
	[ -n "$cmd" ] || continue
	checked=$((checked + 1))
	set -- $cmd
	prog="$1"
	shift
	if [ "$prog" = "godot" ] || [ "$prog" = "${GODOT:-godot}" ]; then
		say "README.md launches godot directly: $cmd"
		say "      every launch goes through scripts/lib_godot.sh, so name a wrapper instead."
		continue
	fi
	if [ ! -x "$ROOT/$prog" ]; then
		say "README.md names $prog, which is missing or not executable."
		continue
	fi
	in_list "$prog" "$HELP_OK" || continue
	help="$(help_text "$prog")" || { say "$prog --help exited non-zero."; continue; }
	# Subcommands and long flags must still be named in the program's own usage.
	for arg in "$@"; do
		case "$arg" in
			--*=*) arg="${arg%%=*}" ;;
			-*) ;;
			*/* | *.*) continue ;;
			*) ;;
		esac
		rg -q -F -- "$arg" "$help" || say "$prog no longer offers '$arg' (README.md: $cmd)"
	done
done <<< "$CMDS"

for prog in $SKIP_RUN; do
	rg -q -F "$prog" "$DOC" || continue
	[ -x "$ROOT/$prog" ] || say "README.md names $prog, which is missing or not executable."
done

[ "$fail" -eq 0 ] || exit 1
echo "check_readme_commands: OK ($checked command(s) in README.md)"
