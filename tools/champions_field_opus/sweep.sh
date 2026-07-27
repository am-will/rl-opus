#!/usr/bin/env bash
# Sweep runtime lighting levers against a Blender still and print the deltas.
#
#   tools/champions_field_opus/sweep.sh <shot> <blender.png> "<args>" ["<args>" ...]
#
# Each quoted argument set is passed to the arena harness verbatim, so anything
# arena_setup.gd understands works:
#
#   --lights BOWL=0.6,TEAM=1.2   scale a light group's energy
#   --ambient 0.3                scale the (unoccluded) sky ambient
#   --exposure 0.9               scale linear exposure ahead of the tonemapper
#
# TOOL=tone_compare switches the readout from region means to the luminance
# percentiles, which is what separates a level error from a curve error.
#
# Every light lives in the import script, where changing one costs a full
# reimport; these levers are the same numbers applied at _ready(), so a bracket
# is one 25 s capture per value instead of one reimport per value. The winner
# gets folded back into arena_post_import.gd and the lever returns to 1.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shot="${1:?usage: sweep.sh <shot> <blender.png> \"<args>\" ...}"
ref="${2:?need a Blender still to measure against}"
shift 2

out="$root/renders/godot_fidelity/sweep"
proj="$root/godot/SlopetLeague"
mkdir -p "$out"

i=0
for spec in "$@"; do
	i=$((i + 1))
	png="$out/${shot}_$i.png"
	# shellcheck disable=SC2086
	godot --path "$proj" --rendering-driver metal -- \
		--capture "$png" --shot "$shot" --fog 0 $spec 2>&1 |
		grep -Ev '^$|mvk-error|Godot Engine|Vulkan 1|Metal 4|capture\]' || true
	echo "=== [$i] $spec"
	python3 "$root/tools/champions_field_opus/${TOOL:-compare_shots}.py" "$ref" "$png" |
		tail -"${LINES:-7}"
done
