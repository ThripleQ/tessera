#!/usr/bin/env python3
"""场景驱动：跑几组对照，看内容量 / 世界尺度 / 合批开关对帧预算的影响。

这里不真的画东西 —— 它统计的是"每帧实际要提交、要模拟多少东西"。
这个数字才决定帧率，而且它跟引擎无关：换 Godot / Bevy 结论一样。

成本模型是可改的估算（见下面的常量），绝对值不用当真，
要看的是同一模型下不同摆法之间的比值。
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from contract.registry import SYSTEMS, check_system_order  # noqa: E402
from runtime.ecs import World  # noqa: E402
import runtime.systems  # noqa: F401,E402  导入即注册系统

FIXED_MS = 4.0            # 引擎固定开销：后处理、UI、音频、动画采样
SUBMIT_MS_PER_DC = 0.008  # 每个 draw call 的 CPU 提交成本
GPU_MS_PER_DC = 0.010     # 每个 draw call 的 GPU 侧固定成本
GPU_MS_PER_TRI = 1.0e-6   # 每三角形
SIM_MS_PER_ACTIVE = 0.003  # 每个激活实体的逻辑成本（3 微秒）
SIM_MS_BASE = 0.30

# 硬预算。加内容时对照这四个数，而不是"跑起来看看卡不卡"。
# igpu 是默认档：核显和 CPU 共享内存带宽，填充率是真正的瓶颈，
# 所以三角形和动态光源都要压得比独显低得多。
BUDGET_PRESETS = {
    "igpu": {"draw_calls": 200, "lights": 4, "triangles": 600_000, "active": 400},
    "discrete": {"draw_calls": 800, "lights": 12, "triangles": 2_500_000, "active": 800},
}

KEYS = ("resident_chunks", "resident_entities", "active", "visible", "draw_calls", "triangles", "lights", "lights_capped")


def dwidth(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def pad(s: str, w: int, right: bool = False) -> str:
    gap = max(0, w - dwidth(s))
    return (" " * gap + s) if right else (s + " " * gap)


def table(headers, rows, aligns):
    widths = []
    for i, h in enumerate(headers):
        widths.append(max(dwidth(h), *(dwidth(r[i]) for r in rows)))
    print("  ".join(pad(h, widths[i], aligns[i]) for i, h in enumerate(headers)))
    print("  ".join("─" * widths[i] for i in range(len(headers))))
    for r in rows:
        print("  ".join(pad(c, widths[i], aligns[i]) for i, c in enumerate(r)))


def measure(pack, n, frames, instancing=True, cramped=False, radius=30.0, light_budget=8):
    w = World(pack, radius=radius, light_budget=light_budget)
    w.populate(n, extent=200.0 if cramped else None)
    warm = frames // 6
    acc = {k: 0.0 for k in KEYS}
    count = 0
    for f in range(frames):
        w.tick += 1
        w.move_camera(w.tick / 30.0)
        s = w.step(1.0 / 30.0, instancing=instancing)
        if f >= warm:
            for k in KEYS:
                acc[k] += getattr(s, k)
            count += 1
    avg = {k: v / count for k, v in acc.items()}
    avg["extent"] = w.extent
    return avg


def estimate(s) -> tuple[float, float, float, float]:
    submit = s["draw_calls"] * SUBMIT_MS_PER_DC
    gpu = s["draw_calls"] * GPU_MS_PER_DC + s["triangles"] * GPU_MS_PER_TRI
    sim = s["active"] * SIM_MS_PER_ACTIVE + SIM_MS_BASE
    return submit, gpu, sim, FIXED_MS + submit + gpu + sim


def ktri(n: float) -> str:
    return f"{n / 1000:.1f}k" if n >= 1000 else str(int(n))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default="build/content.pack.json")
    ap.add_argument("--frames", type=int, default=90)
    ap.add_argument("--tier", choices=sorted(BUDGET_PRESETS), default="igpu", help="预算档位：igpu（默认）/ discrete")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    budget = BUDGET_PRESETS[args.tier]

    pack_path = Path(args.pack)
    if not pack_path.is_absolute():
        pack_path = ROOT / pack_path
    if not pack_path.exists():
        print(f"没有内容包：{pack_path}，先跑 tools/contentc.py", file=sys.stderr)
        return 1
    pack = json.loads(pack_path.read_text(encoding="utf-8"))

    print("内容包")
    print(f"  {pack_path.name}  生成于 {pack['generated_at']}")
    for k, v in sorted(pack["counts"].items()):
        print(f"  {k:<10} {v}")
    if pack.get("patch_summary"):
        for p in pack["patch_summary"]:
            print(f"  patch {p['file']} -> {p['target']}  命中 {len(p['hits'])} 个")

    problems = check_system_order()
    print("\n系统")
    for s in sorted(SYSTEMS, key=lambda x: x.priority):
        print(f"  {s.priority:>4}  {s.name:<14} 读 {','.join(s.reads) or '-':<22} 写 {','.join(s.writes) or '-'}")
    print(f"  写入冲突检查：{'通过' if not problems else '失败'}")
    for p in problems:
        print(f"    ✗ {p}")

    print("\n说明：成本模型 = 固定 4.0ms + draw call × 0.008/0.010ms + 三角形 × 1e-6ms + 激活实体 × 3µs")
    print("      绝对值是估算，看的是不同摆法之间的比值。\n")

    sizes = (100, 1000, 3000, 10000, 30000)
    growth = []
    for n in sizes:
        s = measure(pack, n, args.frames, light_budget=budget["lights"])
        growth.append((n, s))

    print("表一 · 内容变多，密度不变（世界跟着放大）")
    rows = []
    for n, s in growth:
        _, _, _, total = estimate(s)
        rows.append([
            f"{n}",
            f"{int(s['resident_chunks'])}",
            f"{int(s['resident_entities'])}",
            f"{int(s['active'])}",
            f"{int(s['visible'])}",
            f"{int(s['draw_calls'])}",
            ktri(s["triangles"]),
            f"{total:.2f}",
            f"{1000 / total:.0f}",
        ])
    table(["实体数", "驻留区块", "驻留实体", "激活", "可见", "draw call", "三角形", "估算 ms", "约 fps"],
          rows, [True] * 9)

    base = growth[-1][1]
    print("\n表二 · 同样是 30000 个内容，四种摆法")
    variants = [
        ("世界放大 · 密度不变", dict(cramped=False, instancing=True)),
        ("关掉实例化", dict(cramped=False, instancing=False)),
        ("全挤在 200×200 里", dict(cramped=True, instancing=True)),
        ("挤在一起 + 关实例化", dict(cramped=True, instancing=False)),
    ]
    rows = []
    detail = []
    for name, kw in variants:
        s = base if name.startswith("世界放大") else measure(pack, 30000, args.frames,
                                                             light_budget=budget["lights"], **kw)
        submit, gpu, sim, total = estimate(s)
        rows.append([
            name,
            f"{int(s['visible'])}",
            f"{int(s['draw_calls'])}",
            ktri(s["triangles"]),
            f"{int(s['active'])}",
            f"{submit + gpu:.1f}",
            f"{sim:.1f}",
            f"{total:.1f}",
            f"{1000 / total:.0f}",
        ])
        detail.append((name, s, total))
    table(["摆法", "可见", "draw call", "三角形", "激活", "提交+GPU", "逻辑", "估算 ms", "约 fps"],
          rows, [False] + [True] * 8)

    mem = base["resident_entities"] * 128 / (1024 * 1024)
    print(f"\n驻留内存估算：{int(base['resident_entities'])} 个实体 × 128 B ≈ {mem:.2f} MB"
          f"（全量 30000 个，只有驻留部分在内存里）")

    print(f"\n预算检查（30000 内容 · 正常摆法 · {args.tier} 档）")
    checks = [
        ("draw call", base["draw_calls"], budget["draw_calls"], ""),
        ("动态光源", base["lights"], budget["lights"], ""),
        ("三角形", base["triangles"], budget["triangles"], "k"),
        ("激活实体", base["active"], budget["active"], ""),
    ]
    for name, val, cap, unit in checks:
        v = f"{val / 1000:.1f}k" if unit == "k" else f"{int(val)}"
        c = f"{cap / 1000:.0f}k" if unit == "k" else f"{int(cap)}"
        print(f"  {pad(name, 10)} {pad(v, 8, True)} / {pad(c, 8)}  {'OK' if val <= cap else '超预算'}")
    if base["lights_capped"] >= 1:
        print(f"  光源预算每帧收走 {int(base['lights_capped'])} 个超出的光源（内容层不用管，引擎通道强制）")

    if args.json:
        payload = {
            "growth": [{"n": n, **{k: s[k] for k in KEYS}, "estimate_ms": estimate(s)[3]} for n, s in growth],
            "variants": [{"name": n, **{k: s[k] for k in KEYS}, "estimate_ms": t} for n, s, t in detail],
            "model": {
                "fixed_ms": FIXED_MS,
                "submit_ms_per_dc": SUBMIT_MS_PER_DC,
                "gpu_ms_per_dc": GPU_MS_PER_DC,
                "gpu_ms_per_tri": GPU_MS_PER_TRI,
                "sim_ms_per_active": SIM_MS_PER_ACTIVE,
                "sim_ms_base": SIM_MS_BASE,
            },
        }
        out = ROOT / "build" / "frame_report.json"
        out.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        print(f"\n数据 -> {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
