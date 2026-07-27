#!/usr/bin/env python3
"""Extract Octane meshes and textures from the downloaded Unity asset bundle."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import UnityPy


def safe_name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", name).strip("_") or "unnamed"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    environment = UnityPy.load(str(args.bundle))
    manifest: dict[str, list[dict[str, object]]] = {
        "meshes": [],
        "textures": [],
        "materials": [],
    }

    for obj in environment.objects:
        if obj.type.name == "Mesh":
            mesh = obj.read()
            path = args.output / f"{safe_name(mesh.m_Name)}.obj"
            path.write_text(mesh.export(), encoding="utf-8")
            manifest["meshes"].append(
                {
                    "name": mesh.m_Name,
                    "path_id": obj.path_id,
                    "path": path.name,
                    "vertex_count": mesh.m_VertexData.m_VertexCount,
                    "submesh_count": len(mesh.m_SubMeshes),
                }
            )
        elif obj.type.name == "Texture2D":
            texture = obj.read()
            path = args.output / f"{safe_name(texture.m_Name)}.png"
            texture.image.save(path)
            manifest["textures"].append(
                {
                    "name": texture.m_Name,
                    "path_id": obj.path_id,
                    "path": path.name,
                    "size": [texture.m_Width, texture.m_Height],
                }
            )
        elif obj.type.name == "Material":
            material = obj.read()
            manifest["materials"].append(
                {
                    "name": material.m_Name,
                    "path_id": obj.path_id,
                }
            )

    manifest_path = args.output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
