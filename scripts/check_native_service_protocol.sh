#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool "${CXX:-c++}"
require_tool timeout
PUBLICATION="$(mktemp "${TMPDIR:-/tmp}/la_service_publication.XXXXXX")"
NATIVE="$ROOT/addons/local_agents/native"
BIN="$(mktemp "${TMPDIR:-/tmp}/la_service_protocol.XXXXXX")"
trap 'rm -f "$BIN" "$PUBLICATION"' EXIT
"${CXX:-c++}" -std=c++20 -I"$NATIVE/src" "$NATIVE/src/tests/ServiceProtocolTest.cpp" \
 "$NATIVE/src/cli/ServiceProtocol.cpp" -o "$BIN" || exit 2
timeout 5 "$BIN"
protocol_result=$?
if [ "$protocol_result" -ne 0 ]; then
 echo "check_native_service_protocol: wire test exited $protocol_result." >&2
 [ "$protocol_result" -eq 1 ] && exit 1
 exit 2
fi
"${CXX:-c++}" -std=c++20 -pthread -I"$NATIVE/src" -I"$NATIVE/include" \
 "$NATIVE/src/tests/ViewPublicationTest.cpp" "$NATIVE/src/field/ViewPublication.cpp" -o "$PUBLICATION" || exit 2
timeout 15 "$PUBLICATION"
publication_result=$?
if [ "$publication_result" -ne 0 ]; then
 echo "check_native_service_protocol: publication test exited $publication_result." >&2
 [ "$publication_result" -eq 1 ] && exit 1
 exit 2
fi
echo "check_native_service_protocol: OK"
