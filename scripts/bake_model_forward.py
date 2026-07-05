#!/usr/bin/env python3
"""Bake a Y-axis rotation into a GLB's scene-root node(s) so the model's canonical forward
is -Z (matching Godot's look_at convention). Used to normalise mixed asset sources (Kenney
Cube Pets face +Z; Quaternius faces -Z) so the runtime needs no per-model yaw correction.

This is a surgical edit: it only composes a rotation onto the scene's root node transforms in
the JSON chunk and rewrites the container. Vertex/animation/texture data is untouched.

Usage: bake_model_forward.py <model.glb> <degrees>   (e.g. 180 to flip a +Z model to -Z)
"""
import json
import struct
import sys
import math


def quat_mul(a, b):
    # Hamilton product, quaternions as (x, y, z, w).
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def read_glb(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"glTF", "not a GLB"
    total = struct.unpack("<I", data[8:12])[0]
    chunks = []
    off = 12
    while off < total:
        clen = struct.unpack("<I", data[off:off + 4])[0]
        ctype = data[off + 4:off + 8]
        cdata = data[off + 8:off + 8 + clen]
        chunks.append([ctype, cdata])
        off += 8 + clen
    return chunks


def write_glb(path, chunks):
    body = b""
    for ctype, cdata in chunks:
        pad = (4 - (len(cdata) % 4)) % 4
        filler = b"\x20" if ctype == b"JSON" else b"\x00"
        cdata = cdata + filler * pad
        body += struct.pack("<I", len(cdata)) + ctype + cdata
    header = b"glTF" + struct.pack("<II", 2, 12 + len(body))
    with open(path, "wb") as f:
        f.write(header + body)


def bake(path, degrees):
    chunks = read_glb(path)
    ji = next(i for i, c in enumerate(chunks) if c[0] == b"JSON")
    gltf = json.loads(chunks[ji][1])

    half = math.radians(degrees) * 0.5
    q_y = (0.0, math.sin(half), 0.0, math.cos(half))  # rotation about +Y as (x, y, z, w)

    roots = set()
    for scene in gltf.get("scenes", []):
        roots.update(scene.get("nodes", []))
    if not roots:
        roots = {0}

    for ni in roots:
        node = gltf["nodes"][ni]
        if "matrix" in node:
            raise SystemExit("node %d uses a matrix transform; TRS-only supported" % ni)
        cur = tuple(node.get("rotation", [0.0, 0.0, 0.0, 1.0]))
        node["rotation"] = list(quat_mul(q_y, cur))

    chunks[ji][1] = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    write_glb(path, chunks)
    print("baked %.0f deg into %s (roots %s)" % (degrees, path, sorted(roots)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    bake(sys.argv[1], float(sys.argv[2]))
