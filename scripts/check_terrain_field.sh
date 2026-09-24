#!/usr/bin/env bash
# THE GROUND READS THE LEAF IT STANDS IN. The field's per-leaf state reaches the terrain shader on a graded
# grid, and a turned, displaced body's fragment finds its leaf in the body's frame, not the world's.
# EXIT 0 held · 1 broken · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/check_terrain_glow.sh" field
