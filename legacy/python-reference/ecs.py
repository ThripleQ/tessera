"""世界层：分块、流式、激活。

顺序很重要：
  区块级粗剔除 -> 实体级激活 -> 跑系统 -> 动态区块迁移 -> 视锥剔除 -> 合批

"可见" 和 "激活" 是两个不同的集合，别混：
  可见但不激活 = 在远处看得到，但逻辑冻结（省钱的关键状态）
  激活但不可见 = 就在你背后，逻辑还在跑（音效、威胁感需要）
"""

from __future__ import annotations

import math
import random

from contract.registry import MESHES, SYSTEMS
from runtime.render import Stats, batch, cull, limit_lights

CHUNK = 40.0
FOV_HALF = math.radians(35.0)


class Entity:
    __slots__ = ("eid", "cid", "x", "z", "comps", "seed", "rng", "_chunk")

    def __init__(self, eid: int, cid: str, x: float, z: float, comps: dict, seed: int):
        self.eid = eid
        self.cid = cid
        self.x = x
        self.z = z
        self.comps = comps
        self.seed = seed
        self.rng = None  # 惰性创建：大部分实体一辈子用不到随机数
        self._chunk = (int(x // CHUNK), int(z // CHUNK))


class World:
    def __init__(self, pack: dict, density: float = 0.02, far: float = 120.0, radius: float = 30.0,
                 seed: int = 7, light_budget: int = 8):
        self.pack = pack
        self.density = density  # 每平方米多少个内容实体
        self.far = far
        self.radius = radius
        self.seed = seed
        self.light_budget = light_budget
        self.entities: list[Entity] = []
        self.grid: dict[tuple[int, int], list[Entity]] = {}
        self.extent = 200.0
        self.tick = 0
        self.camera = {"x": 0.0, "z": 0.0, "yaw": 0.0}

    def spawnable(self) -> list[str]:
        out = []
        for cid, body in self.pack["entities"].items():
            if body["kind"] != "archetype":
                continue
            if "model" not in body.get("components", {}):
                continue  # 没有外观的是纯模板，不摆进世界
            out.append(cid)
        return sorted(out)

    def populate(self, n: int, extent: float | None = None) -> None:
        ids = self.spawnable()
        if not ids:
            raise SystemExit("内容里没有可摆放的 archetype")
        if extent is None:
            extent = max(80.0, math.sqrt(n / self.density))
        self.extent = extent

        rng = random.Random(self.seed)
        self.entities = []
        self.grid = {}

        # 原型只克隆一次：内容实体的组件是扁平字典，浅拷贝一层就够，
        # 不需要 deepcopy。这一步在 3 万个实体上差了两个数量级。
        templates: dict[str, dict] = {}
        for cid in ids:
            src = self.pack["entities"][cid]["components"]
            t = {k: dict(v) for k, v in src.items()}
            h = t.get("health")
            if h is not None and h["hp"] <= 0:
                h["hp"] = h["max"]
            templates[cid] = t

        for i in range(n):
            cid = ids[i % len(ids)]
            e = Entity(
                i, cid,
                rng.uniform(0.0, extent), rng.uniform(0.0, extent),
                {k: dict(v) for k, v in templates[cid].items()},
                self.seed * 1_000_003 + i,
            )
            self.entities.append(e)
            self.grid.setdefault(e._chunk, []).append(e)

        self.camera["x"] = extent * 0.5
        self.camera["z"] = extent * 0.5
        self.camera["yaw"] = 0.0
        self.tick = 0

    def move_camera(self, t: float) -> None:
        m = max(10.0, self.extent * 0.12)
        span = max(1.0, self.extent - 2 * m)
        x = m + span * (0.5 + 0.5 * math.sin(t * 0.31))
        z = m + span * (0.5 + 0.5 * math.sin(t * 0.17 + 1.3))
        dx = x - self.camera["x"]
        dz = z - self.camera["z"]
        if abs(dx) + abs(dz) > 1e-9:
            self.camera["yaw"] = math.atan2(dx, dz)
        self.camera["x"] = x
        self.camera["z"] = z

    def step(self, dt: float, instancing: bool = True) -> Stats:
        cam = self.camera
        cx, cz = cam["x"], cam["z"]
        fx, fz = math.sin(cam["yaw"]), math.cos(cam["yaw"])
        cos_half = math.cos(FOV_HALF)

        cgx, cgz = int(cx // CHUNK), int(cz // CHUNK)
        reach = int(self.far // CHUNK) + 1
        stats = Stats()
        candidates: list[Entity] = []

        for gx in range(cgx - reach, cgx + reach + 1):
            for gz in range(cgz - reach, cgz + reach + 1):
                bucket = self.grid.get((gx, gz))
                if not bucket:
                    continue
                bx = (gx + 0.5) * CHUNK - cx
                bz = (gz + 0.5) * CHUNK - cz
                if math.hypot(bx, bz) > self.far + CHUNK * 1.5:
                    continue  # 整块不参与后面所有计算
                stats.resident_chunks += 1
                stats.resident_entities += len(bucket)
                candidates.extend(bucket)

        r2 = self.radius * self.radius
        active = []
        for e in candidates:
            dx = e.x - cx
            dz = e.z - cz
            if dx * dx + dz * dz <= r2:
                active.append(e)
        stats.active = len(active)

        for spec in sorted(SYSTEMS, key=lambda s: s.priority):
            if spec.fn is not None:
                spec.fn(self, active, dt)

        self._migrate(active)

        visible = cull(candidates, cx, cz, self.far, fx, fz, cos_half)
        stats.visible = len(visible)
        stats.draw_calls, stats.triangles = batch(visible, instancing, MESHES)
        stats.lights, stats.lights_capped = limit_lights(visible, cx, cz, self.light_budget)
        return stats

    def _migrate(self, moved: list[Entity]) -> None:
        """移动过的实体换区块。真实引擎用空间哈希做这件事，语义一样。"""
        for e in moved:
            k = (int(e.x // CHUNK), int(e.z // CHUNK))
            if k == e._chunk:
                continue
            old = self.grid.get(e._chunk)
            if old is not None:
                try:
                    old.remove(e)
                except ValueError:
                    pass
            self.grid.setdefault(k, []).append(e)
            e._chunk = k
