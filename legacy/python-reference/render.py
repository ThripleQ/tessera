"""渲染通道：视锥剔除 + 合批。

这一层是「固定通道」——它没有扩展点，也刻意不给扩展点。
理由：帧率是由这里决定的，如果允许内容层插手这里，性能就没法保证。
内容能影响的只有"提交什么东西"，不能影响"怎么提交"。
"""

from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class Stats:
    resident_chunks: int = 0
    resident_entities: int = 0
    active: int = 0
    visible: int = 0
    draw_calls: int = 0
    triangles: int = 0
    lights: int = 0
    lights_capped: int = 0


LIGHT_BUDGET = 8


def limit_lights(entities, cx: float, cz: float, budget: int = LIGHT_BUDGET) -> tuple[int, int]:
    """光源预算由引擎通道强制，不由内容自觉。

    内容可以随便加发光怪，这里每帧只点亮最近的 budget 个。
    这是"内容开放、预算封闭"的典型形态：设计上不禁止，但越界会被系统收走。
    返回 (点亮数, 被熄灭数)。
    """
    lit = []
    for e in entities:
        li = e.comps.get("light")
        if li is None:
            continue
        if li["intensity"] <= 0.0:
            continue
        lit.append(e)

    if len(lit) <= budget:
        for e in lit:
            e.comps["light"]["_on"] = True
        return len(lit), 0

    lit.sort(key=lambda e: (e.x - cx) ** 2 + (e.z - cz) ** 2)
    for e in lit[:budget]:
        e.comps["light"]["_on"] = True
    for e in lit[budget:]:
        e.comps["light"]["_on"] = False
    return budget, len(lit) - budget


def cull(entities, cx: float, cz: float, far: float, fx: float, fz: float, cos_half: float) -> list:
    """距离剔除 + 视锥剔除。相机朝向由 (fx, fz) 给出。"""
    far2 = far * far
    out = []
    for e in entities:
        dx = e.x - cx
        dz = e.z - cz
        d2 = dx * dx + dz * dz
        if d2 > far2:
            continue
        d = math.sqrt(d2)
        if d < 1e-6 or (dx * fx + dz * fz) / d >= cos_half:
            out.append(e)
    return out


def batch(entities, instancing: bool, meshes: dict) -> tuple[int, int]:
    """按 (网格, 配色) 分组。

    同一个网格换配色不应该多一个 draw call —— 那是材质参数，不是材质。
    关掉实例化时退化成"一物一次提交"，用来看清楚合批到底值多少。
    """
    groups: dict[tuple, int] = {}
    tris = 0
    for e in entities:
        m = e.comps.get("model")
        if m is None:
            continue
        mesh = m["mesh"]
        tris += meshes.get(mesh, 0)
        if instancing:
            key = (mesh, m["palette"])
        else:
            key = (mesh, m["palette"], e.eid)
        groups[key] = groups.get(key, 0) + 1
    return len(groups), tris
