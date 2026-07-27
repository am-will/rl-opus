#!/usr/bin/env bash
# Capture the Godot arena from the ported Blender shots.
#
#   tools/champions_field_opus/capture_godot.sh <tag> [shot ...]
#
# Writes renders/godot_fidelity/<tag>_<shot>.png, one Godot run per shot
# (the harness renders 45 frames so TAA and glow settle, then quits).
# Defaults to the three shots that read the lighting best.
#
# Volumetric fog defaults OFF here because it ships off. It used to default to
# 1.0, which meant every measurement in this directory was of a configuration
# nobody would ever see -- and the fog is blue, so it was quietly holding the
# boards up by ~14/255 and adding most of their apparent saturation. `FOG=1
# capture_godot.sh ...` still turns it on.
#
# Metal, not Vulkan: MoltenVK here cannot persist Godot's pipeline cache
# ("Error writing pipeline cache data"), so every Vulkan run recompiles every
# shader from scratch and a single capture takes ~9 minutes. The same capture
# on the native Metal driver takes 25 seconds.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tag="${1:?usage: capture_godot.sh <tag> [shot ...]}"
shift
shots=("${@:-}")
[ -z "${shots[0]}" ] && shots=(hero kickoff broadcast)

out="$root/renders/godot_fidelity"
proj="$root/godot/SlopetLeague"
mkdir -p "$out"

# Editing the post-import script does not change the .glb's hash, so Godot
# happily reuses the stale .scn and none of the light or material fixes land.
# Dropping the cached scene forces the import to run again.
post="$proj/import/arena_post_import.gd"
scn=$(ls "$proj/.godot/imported/"champions_field.glb-*.scn 2>/dev/null | head -1 || true)
if [ -z "$scn" ] || [ "$post" -nt "$scn" ]; then
	echo "[import] post-import script changed, reimporting the arena"
	rm -f "$proj/.godot/imported/"champions_field.glb-*
	godot --path "$proj" --headless --import 2>&1 |
		grep -Ei 'error|failed' || true
fi

for shot in "${shots[@]}"; do
	png="$out/${tag}_${shot}.png"
	godot --path "$proj" --rendering-driver metal -- \
		--capture "$png" --shot "$shot" --fog "${FOG:-0}" 2>&1 |
		grep -Ev '^$|mvk-error|Godot Engine|Vulkan 1' || true
	echo "[shot] $png"
done
