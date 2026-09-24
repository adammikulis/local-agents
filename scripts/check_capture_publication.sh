#!/usr/bin/env bash
# A FACE-STATE CAPTURE IS PUBLISHED ONLY BY A RUN THAT FINISHED. sim_run.sh hands the recorder the partial
# name and publishes it through lib_slice_capture.sh, so a run killed, timed out or logging engine errors
# leaves nothing under the name a gate reads, and never a partial file beside it.
# EXIT 0 held · 1 a run that did not finish published, or one that did was refused · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
LIB="$ROOT/scripts/lib_slice_capture.sh"
[ -f "$LIB" ] || { echo "check_capture_publication: missing ${LIB#"$ROOT"/}." >&2; exit 2; }
. "$LIB"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/la_cap_pub.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

fail=0
checked=0
# The codes sim_run.sh exits with once the run finished: clean, and its three physics verdicts.
for rc in 0 122 123 126 2 3 4 5 6 124 125 137; do
	cap="$WORK/cap_$rc.json"
	printf '{"samples":[]}' > "$(la_slice_capture_partial "$cap")"
	la_publish_slice_capture "$cap" "$rc"
	case "$rc" in 0|122|123|126) want=1 ;; *) want=0 ;; esac
	have=0
	[ -f "$cap" ] && have=1
	checked=$((checked + 1))
	if [ "$have" -ne "$want" ]; then
		echo "FAIL: a run exiting $rc $([ "$have" -eq 1 ] && echo published || echo withheld) its capture." >&2
		fail=1
	fi
	if [ -e "$(la_slice_capture_partial "$cap")" ]; then
		echo "FAIL: a run exiting $rc left its partial capture beside the name." >&2
		fail=1
	fi
done
# One script hands the recorder a name: sim_run.sh, the partial one, published through the library.
names="$(rg -l -F 'LA_SLICE_CAPTURE=' "$ROOT/scripts" -g '*.sh' -g '!check_capture_publication.sh')"
partial="$(rg -l -F 'LA_SLICE_CAPTURE="$(la_slice_capture_partial "$SLICE_CAPTURE")"' "$ROOT/scripts" -g '*.sh' -g '!check_capture_publication.sh')"
publish="$(rg -l -F 'la_publish_slice_capture "$SLICE_CAPTURE" "$RC"' "$ROOT/scripts" -g '*.sh' -g '!check_capture_publication.sh')"
if [ "${names##*/}" != "sim_run.sh" ] || [ "$partial" != "$names" ] || [ "$publish" != "$names" ]; then
	echo "FAIL: the recorder is handed a name no finished run publishes through lib_slice_capture.sh:" >&2
	printf '  %s\n' $names >&2
	fail=1
fi
echo "CAPTURE_PUBLICATION={\"codes\":$checked,\"failures\":$fail}"
[ "$fail" -eq 0 ] || exit 1
echo "check_capture_publication: OK"
