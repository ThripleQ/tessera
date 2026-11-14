"""生成 mods/asset_demo/assets/meshes/prop_crate.gltf —— 一个 8 三角形钻石。

为什么仓库里放的是自造的最小 glTF，而不是网上下载的模型：
  * CI 必须离线可验，不能依赖某个资源站当天能访问、文件没被换掉；
  * 纯文本 JSON + 内嵌 base64 buffer，几 KB，进版本库没有二进制噪音；
  * 它是**通道验收样品**，不是美术内容。真实资源包怎么放见 ASSETS.md。

几何：y=0.4 处一个正方形环，上下各一个顶点，8 个三角形。
原点在底面中心、高 0.8 米，和内置 prop_crate 的占位一致。
三角形数 8 ≠ 内置 12，自检和探针靠这个差值确认"真的换了"。
"""

import base64
import json
import math
import struct
from pathlib import Path

UP = (0.0, 0.8, 0.0)
DOWN = (0.0, 0.0, 0.0)
RING = [
    (-0.4, 0.4, -0.4),
    (0.4, 0.4, -0.4),
    (0.4, 0.4, 0.4),
    (-0.4, 0.4, 0.4),
]


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def length(v):
    return math.sqrt(sum(x * x for x in v))


def norm(v):
    n = length(v)
    return tuple(x / n for x in v) if n > 1e-9 else (0.0, 1.0, 0.0)


def tri(a, b, c):
    """保证 winding 朝外：法线应大致背离几何中心。"""
    center = ((a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3,
              (a[2] + b[2] + c[2]) / 3)
    n = norm(cross(sub(b, a), sub(c, a)))
    outward = sub(center, (0.0, 0.4, 0.0))
    if sum(n[i] * outward[i] for i in range(3)) < 0:
        b, c = c, b
        n = norm(cross(sub(b, a), sub(c, a)))
    return (a, b, c), n


faces = []
for i in range(4):
    a, b = RING[i], RING[(i + 1) % 4]
    faces.append(tri(UP, a, b))
    faces.append(tri(DOWN, b, a))

positions = []
normals = []
uvs = []
for (a, b, c), n in faces:
    for v, uv in zip((a, b, c), ((0.0, 0.0), (1.0, 0.0), (0.5, 1.0))):
        positions.extend(v)
        normals.extend(n)
        uvs.extend(uv)

count = len(positions) // 3
raw = (
    struct.pack("<%df" % len(positions), *positions)
    + struct.pack("<%df" % len(normals), *normals)
    + struct.pack("<%df" % len(uvs), *uvs)
)
b64 = base64.b64encode(raw).decode("ascii")

pbytes = len(positions) * 4
nbytes = len(normals) * 4
uvbytes = len(uvs) * 4

xs = positions[0::3]
ys = positions[1::3]
zs = positions[2::3]

doc = {
    "asset": {"version": "2.0", "generator": "tessera asset_demo sample"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"mesh": 0, "name": "diamond_crate"}],
    "meshes": [{"name": "diamond_crate", "primitives": [{
        "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
        "mode": 4,
    }]}],
    "buffers": [{
        "uri": "data:application/octet-stream;base64," + b64,
        "byteLength": len(raw),
    }],
    "bufferViews": [
        {"buffer": 0, "byteOffset": 0, "byteLength": pbytes, "target": 34962},
        {"buffer": 0, "byteOffset": pbytes, "byteLength": nbytes, "target": 34962},
        {"buffer": 0, "byteOffset": pbytes + nbytes,
         "byteLength": uvbytes, "target": 34962},
    ],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": count, "type": "VEC3",
         "min": [min(xs), min(ys), min(zs)], "max": [max(xs), max(ys), max(zs)]},
        {"bufferView": 1, "componentType": 5126, "count": count, "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": count, "type": "VEC2"},
    ],
}

out = Path(__file__).parent / "assets" / "meshes" / "prop_crate.gltf"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
print("wrote %s：%d 顶点 / %d 三角形 / %d 字节 buffer"
      % (out, count, count // 3, len(raw)))
