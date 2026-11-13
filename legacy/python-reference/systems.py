"""游戏系统 —— 唯一对"玩法"开放的扩展点。

写一个新系统时照这四条做：
  1. 用 @system 声明读哪些组件、写哪些组件、优先级多少
  2. 只处理传进来的 active 列表，不要自己去 world.entities 里翻
  3. 不要直接调用别的系统 —— 系统之间只能通过组件交流
  4. 循环里别建临时字典 / 别做深拷贝，那是帧预算的隐形漏斗

priority 越小越先跑。同一个组件如果有两个系统写，优先级必须不同，
否则启动时的 check_system_order() 会直接拒绝运行 —— 这是故意的。
"""

from __future__ import annotations

import math
import random

from contract.registry import system


@system("health_regen", priority=100, reads=("health",), writes=("health",))
def health_regen(world, active, dt: float) -> None:
    for e in active:
        h = e.comps.get("health")
        if h is None or h["regen"] <= 0.0:
            continue
        if h["hp"] < h["max"]:
            h["hp"] = min(h["max"], h["hp"] + h["regen"] * dt)


@system("torch_flicker", priority=150, reads=("light",), writes=("light",))
def torch_flicker(world, active, dt: float) -> None:
    """闪烁很便宜，但它说明一件事：任何"每帧都要动一下"的属性都在花帧预算。"""
    for e in active:
        li = e.comps.get("light")
        if li is None or not li["flicker"]:
            continue
        li["intensity"] = 1.0 + 0.35 * math.sin(world.tick * 0.4 + e.eid)


@system("ai_move", priority=200, reads=("ai", "move", "health"), writes=("move",))
def ai_move(world, active, dt: float) -> None:
    cam = world.camera
    cx, cz = cam["x"], cam["z"]
    for e in active:
        mv = e.comps.get("move")
        if mv is None or mv["speed"] <= 0.0:
            continue
        h = e.comps.get("health")
        if h is not None and h["hp"] <= 0:
            continue

        ai = e.comps.get("ai")
        dx = cx - e.x
        dz = cz - e.z

        if ai is not None and ai["brain"] in ("charger", "ambusher"):
            dist = math.hypot(dx, dz)
            if 1e-6 < dist < ai["aggro_radius"]:
                step = mv["speed"] * dt
                e.x += dx / dist * step
                e.z += dz / dist * step
                continue

        if mv["wander"] > 0.0:
            r = e.rng
            if r is None:
                r = e.rng = random.Random(e.seed)
            step = mv["wander"] * dt
            e.x += r.uniform(-1.0, 1.0) * step
            e.z += r.uniform(-1.0, 1.0) * step
