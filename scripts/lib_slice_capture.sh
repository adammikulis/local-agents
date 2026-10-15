#!/usr/bin/env bash
# A FACE-STATE CAPTURE IS A RECORD OF A RUN THAT FINISHED. The recorder writes beside the name it was
# given; sim_run.sh publishes the file under that name only when the run exited with a code a finished
# run exits with, and a killed or erroring run's samples are deleted.

# $1 the capture name a caller asked for; the path the recorder writes.
la_slice_capture_partial() {
	printf '%s.partial' "$1"
}

# $1 the capture name, $2 the run's exit code. Returns 0 when the capture was published.
la_publish_slice_capture() {
	local partial
	partial="$(la_slice_capture_partial "$1")"
	case "$2" in
		0|122|123|126) mv -f "$partial" "$1" 2>/dev/null ;;
		*) rm -f "$partial"; return 1 ;;
	esac
}
