#!/usr/bin/env bash
# Capture a trailer/marketing shot to video via Godot's movie-maker (deterministic — renders every frame at a
# fixed fps, ignoring realtime). LATrailerDirector drives a scripted camera + timed events and auto-quits.
# Shots are independent — capture each in its own run and cut them together (see docs/TRAILER.md).
#
#   scripts/capture_trailer.sh <shot> [out.avi]
#   shots: serenity | eruption | reveal   (add more in world/TrailerDirector.gd)
#
# Pins the music seed so retakes match; runs off-screen + focus-safe via run_sim_offscreen.sh.
set -euo pipefail
SHOT="${1:-eruption}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Default output: a `trailer/` folder at the repo root (gitignored) — easy to find. Override with arg 2.
mkdir -p "$DIR/trailer"
OUT="${2:-$DIR/trailer/${SHOT}.avi}"
export LA_MUSIC_SEED="${LA_MUSIC_SEED:-1234}"
export LA_NO_STREAMER=1
export LA_RES="${LA_RES:-1280x720}"
SCENE="addons/local_agents/scenes/simulation/voxel/VoxelWorld.tscn"
echo "[trailer] shot=$SHOT out=$OUT res=$LA_RES"
# --write-movie tells Godot to record the viewport to OUT; the director quits when the shot ends → file finalizes.
"$DIR/scripts/run_sim_offscreen.sh" --path "$DIR" --write-movie "$OUT" "$SCENE" -- --trailer-shot="$SHOT" --sandbox
echo "TRAILER_CAPTURED=$OUT"
# Godot writes MJPEG .avi (QuickTime can't open it). Transcode to H.264 mp4 (yuv420p = QuickTime-friendly).
if command -v ffmpeg >/dev/null 2>&1 && [ -f "$OUT" ]; then
	MP4="${OUT%.avi}.mp4"
	ffmpeg -y -loglevel error -i "$OUT" -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart "$MP4" \
		&& echo "TRAILER_MP4=$MP4  ← open this (QuickTime-friendly)"
fi
ls -la "$OUT" 2>/dev/null || echo "[trailer] WARNING: no output file produced"
