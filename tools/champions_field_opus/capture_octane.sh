#!/usr/bin/env bash
# Photograph the Octane close up, under the arena's own lighting.
#
#   tools/champions_field_opus/capture_octane.sh <tag> [view ...]
#
# Writes renders/octane_godot/<tag>_<view>.png, one Godot run per view. Views
# are the keys of VIEWS in tests/octane_shot.gd. TEAM=orange|both picks the
# paint; the default is blue, which is the side the reference stills show.
#
# Metal, not Vulkan — same reason as capture_godot.sh: MoltenVK here cannot
# persist the pipeline cache, so a Vulkan run recompiles every shader.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="${1:?usage: capture_octane.sh <tag> [view ...]}"
shift
views=("${@:-}")
[ -z "${views[0]}" ] && views=(rear3q front3q deck)

out="$root/renders/octane_godot"
proj="$root/godot/SlopetLeague"
mkdir -p "$out"

for view in "${views[@]}"; do
	png="$out/${tag}_${view}.png"
	# `--shot none` stops ShotCams claiming the viewport: it treats a bare
	# `--capture` outside the game scene as "photograph the arena" and defers a
	# make_current that would otherwise frame the pitch, not the car.
	godot --path "$proj" --rendering-driver metal res://tests/octane_shot.tscn -- \
		--capture "$png" --shot none --view "$view" --team "${TEAM:-blue}" \
		--fog "${FOG:-0.12}" 2>&1 |
		grep -Ev '^$|mvk-error|Godot Engine|Vulkan 1' || true
	echo "[shot] $png"
done
