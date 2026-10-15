#!/usr/bin/env bash
la_stream_fixture_start() {
    local root="$1" work="$2"
    command -v python3 >/dev/null 2>&1 || return 2
    : > "$work/stream_port" || return 2
    python3 "$root/addons/local_agents/tests/support/chat_stream_server.py" "$work/stream_port" &
    LA_STREAM_FIXTURE_PID=$!
    local attempt
    for attempt in {1..50}; do
        kill -0 "$LA_STREAM_FIXTURE_PID" 2>/dev/null || return 2
        [ -s "$work/stream_port" ] && break
        sleep 0.1
    done
    [ -s "$work/stream_port" ] || return 2
    export LA_STREAM_TEST_PORT="$(cat "$work/stream_port")"
}

la_stream_fixture_stop() {
    if [ -n "${LA_STREAM_FIXTURE_PID:-}" ]; then
        kill "$LA_STREAM_FIXTURE_PID" 2>/dev/null || true
        wait "$LA_STREAM_FIXTURE_PID" 2>/dev/null || true
        unset LA_STREAM_FIXTURE_PID LA_STREAM_TEST_PORT
    fi
}
