#!/usr/bin/env python3
"""热重载：改内容 -> 立刻看到"改了什么"。

  --once    编译一次，和上次的产物比对差异（适合接在编辑器保存钩子上）
  --watch   持续监听，任何一个 toml 变了就重编译

它不重启运行时 —— 真实项目里运行时订阅 pack 变化、只重建受影响的实体。
这个工具先把最难的那半件做对：**准确说出哪一条内容的哪个字段变了**。
大部分热重载翻车都翻在"改了但看不出来到底哪变了"。
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from tools.contentc import build_pack, emit_binary  # noqa: E402

PACK = ROOT / "build" / "content.pack.json"
BIN = ROOT / "build" / "content.pack.bin"
LAST = ROOT / "build" / ".last_pack.json"


def flatten(body: dict) -> dict[str, str]:
    """把一条内容压成 {组件.字段: 值}，用来做字段级 diff。"""
    out: dict[str, str] = {}
    for cname, cval in body.get("components", {}).items():
        if isinstance(cval, dict):
            for fname, fval in cval.items():
                out[f"{cname}.{fname}"] = str(fval)
        else:
            out[cname] = str(cval)
    for k in ("kind", "name"):
        if k in body:
            out[f"@{k}"] = str(body[k])
    out["@tags"] = ",".join(body.get("tags", []))
    return out


def diff(old: dict, new: dict) -> int:
    """打印差异，返回变更条数。"""
    old_ids, new_ids = set(old), set(new)
    added = sorted(new_ids - old_ids)
    removed = sorted(old_ids - new_ids)
    changed = []

    for cid in sorted(old_ids & new_ids):
        a, b = flatten(old[cid]), flatten(new[cid])
        keys = set(a) | set(b)
        delta = [(k, a.get(k, "—"), b.get(k, "—")) for k in sorted(keys) if a.get(k) != b.get(k)]
        if delta:
            changed.append((cid, delta))

    if not (added or removed or changed):
        print("  没有变化")
        return 0

    for cid in added:
        print(f"  + 新增 {cid}")
    for cid in removed:
        print(f"  - 删除 {cid}")
    for cid, delta in changed:
        print(f"  ~ 修改 {cid}")
        for k, a, b in delta:
            print(f"       {k}: {a} -> {b}")
    return len(added) + len(removed) + len(changed)


def snapshot(dirs: list[str]) -> dict[str, float]:
    stamps: dict[str, float] = {}
    for d in dirs:
        base = Path(d)
        if not base.exists():
            continue
        for p in base.rglob("*.toml"):
            stamps[str(p)] = p.stat().st_mtime
    return stamps


def compile_once(dirs: list[str]) -> bool:
    pack, errors, warnings = build_pack(dirs)
    if errors:
        print(f"编译失败，{len(errors)} 个问题（运行中的版本保持不变）：")
        for e in errors:
            print(f"  ✗ {e}")
        return False

    old = {}
    if LAST.exists():
        try:
            old = json.loads(LAST.read_text(encoding="utf-8")).get("entities", {})
        except json.JSONDecodeError:
            old = {}

    n = diff(old, pack["entities"])
    for w in warnings:
        print(f"  ! {w}")

    PACK.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(pack, ensure_ascii=False, indent=1)
    PACK.write_text(text, encoding="utf-8")
    LAST.write_text(text, encoding="utf-8")
    # 二进制包必须同步刷新，否则原生渲染器读到的还是上一版内容 ——
    # "改完没生效"十有八九是这个原因。
    try:
        emit_binary(pack, BIN, quiet=True)
    except Exception as exc:  # noqa: BLE001
        print(f"  ! 二进制包写出失败：{exc}")
    print(f"  {sum(pack['counts'].values())} 条内容已就绪，{n} 处变更" if n else f"  {sum(pack['counts'].values())} 条内容已就绪")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--content", action="append", required=True)
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--once", action="store_true", help="编译一次后退出（默认行为，显式写出来更清楚）")
    ap.add_argument("--interval", type=float, default=0.5)
    args = ap.parse_args()

    print("编译")
    compile_once(args.content)
    if not args.watch:
        return 0

    print(f"\n监听 {', '.join(args.content)}（Ctrl-C 退出）")
    stamps = snapshot(args.content)
    try:
        while True:
            time.sleep(args.interval)
            now = snapshot(args.content)
            if now == stamps:
                continue
            changed = [p for p in now if stamps.get(p) != now[p]]
            stamps = now
            print(f"\n检测到 {len(changed)} 个文件变动：")
            for p in changed:
                print(f"  · {Path(p).relative_to(ROOT)}")
            compile_once(args.content)
    except KeyboardInterrupt:
        print("\n退出")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
