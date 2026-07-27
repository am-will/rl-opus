#!/usr/bin/env bash
# Capture the Godot arena from the ported Blender shots.
#
#   tools/champions_field_opus/capture_godot.sh <tag> [shot ...]
#
# Writes renders/godot_fidelity/<tag>_<shot>.png, one Godot run per shot
# (the harness renders 45 frames so TAA and glow settle, then quits).
# Defaults to the three shots that read the lighting best.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="${1:?usage: capture_godot.sh <tag> [shot ...]}"
shift
shots=("${@:-}")
[ -z "${shots[0]}" ] && shots=(hero kickoff broadcast)

out="$root/renders/godot_fidelity"
mkdir -p "$out"

for shot in "${shots[@]}"; do
	png="$out/${tag}_${shot}.png"
	godot --path "$root/godot/SlopetLeague" --rendering-driver vulkan -- \
		--capture "$png" --shot "$shot" 2>&1 |
		grep -Ev '^$|mvk-error|Godot Engine|Vulkan 1' || true
	echo "[shot] $png"
done
