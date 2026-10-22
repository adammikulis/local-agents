#!/usr/bin/env bash
# THE SHOT ARMS: one launch of one world, read by every gate holding a claim about it. Declared here and
# nowhere else. Under a lint an arm stands in the shared capture, so the second gate to name it launches
# nothing; with no capture each gate launches its own.
#   la_shot_arm <name> <scratch dir>   prints the arm's directory: run.log, rc, and the PNGs it saved.
# EXIT 0 the arm stands (read its rc) · 2 no such arm, or no directory to hold it.
LA_ARM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$LA_ARM_ROOT/scripts/lib_capture.sh"

LA_ARM_SCENE_R0="addons/local_agents/examples/SliceRung0Demo.tscn"
LA_ARM_SCENE_R1="addons/local_agents/examples/SliceRung1Demo.tscn"
LA_ARM_SCENE_WORLD="addons/local_agents/game/VoxelWorld.tscn"
LA_ARM_BOX_POLE="0,surface,0,3,24,3,5120,10"
# The eye-level poses and the distances up and back, then over the box. The first two are the poses the
# look claim reads; each pose differs from the one before it.
LA_ARM_PROTOCOL_POSES="30:-3:0;200:-15:0;2000:-35:0;2000:-35:180;10000:-60:0"
LA_ARM_BLOCKS_UNDER_M=1000
LA_ARM_OVER_GROUND="vectors,test_masses,box_outline,water_particles,water_surface"

la_arm_cmd() {  # <name> <dir>: fills LA_ARM_CMD
	local run="$LA_ARM_ROOT/scripts/run_sim_offscreen.sh" shoot="$LA_ARM_ROOT/scripts/shoot_demo.sh" poses
	case "$1" in
		protocol)
			LA_ARM_CMD=(env "LA_SHOTS=$LA_ARM_PROTOCOL_POSES" "$shoot" "$LA_ARM_SCENE_R0" "$2") ;;
		blocks)
			poses="$("$shoot" "$LA_ARM_SCENE_R1" --print-shots | tr ';' '\n' \
				| awk -F: -v u="$LA_ARM_BLOCKS_UNDER_M" 'NF == 3 && $1 + 0 < u' | paste -sd ';' -)" || return 2
			LA_ARM_CMD=(env "LA_SHOTS=$poses" "$shoot" "$LA_ARM_SCENE_R1" "$2" --without=terrain
				-- --debug-field=blocks "--ablate=$LA_ARM_OVER_GROUND") ;;
		outline)
			# The pose that parts a pillar's foot from its fade height by the most pixels, on the two corners no
			# relief hides; what moves on its own is ablated so the two frames differ by the outline alone.
			LA_ARM_CMD=(env LA_RUN_TIMEOUT=110 "$run" --path "$LA_ARM_ROOT" "$LA_ARM_SCENE_R1" -- --sandbox
				"--shoot=$2/shot.png" --shots=6000:-40:180 --local-hour=12 --shoot-step=60 --shoot-frames=150
				--shoot-size=1280x800 --ablate=vectors,test_masses --shot-without=box_outline) ;;
		air)
			LA_ARM_CMD=(env "LA_SLICE_BOX=$LA_ARM_BOX_POLE" LA_RUN_TIMEOUT=110 "$run" --path "$LA_ARM_ROOT"
				"$LA_ARM_SCENE_WORLD" -- --sandbox --ui --rung=2 --planet-only "--shoot=$2/shot.png"
				--shots=2000:-89:0 --local-hour=12 --shoot-frames=90 --shoot-size=320x200) ;;
		*) return 2 ;;
	esac
}

la_shot_arm() {
	local name="$1" home="$2" cap dir rc
	if cap="$(la_cap_dir)"; then dir="$cap/arms/$name"; else dir="$home/arms/$name"; fi
	if [ ! -f "$dir/COMPLETE" ]; then
		mkdir -p "$dir" || return 2
		rm -f "$dir"/*
		la_arm_cmd "$name" "$dir" || { echo "la_shot_arm: no arm named '$name'." >&2; return 2; }
		( cd "$LA_ARM_ROOT" && "${LA_ARM_CMD[@]}" ) > "$dir/run.log" 2>&1
		rc=$?
		printf '%s\n' "$rc" > "$dir/rc"
		: > "$dir/COMPLETE"
	fi
	printf '%s' "$dir"
}
