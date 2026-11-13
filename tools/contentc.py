#!/usr/bin/env python3
"""contentc —— 内容编译器

把散落的内容文件编译成一个运行时可用的内容包。四步：

  1. 解析   TOML -> dict，检查 api_version / kind
  2. 合成   extends 继承链（带循环检测）+ patch 覆写（glob 目标）
  3. 校验   组件名、字段名、类型、范围、枚举，全部对着 contract/registry.py
  4. 打包   输出单一 pack 文件；运行时不碰原始内容文件

为什么要有"编译"这一步：
  内容可以随便改，但"改错了"必须在几毫秒内告诉你，而不是让游戏跑起来再崩。
  校验失败就不产出 pack —— 坏的构建产物永远到不了运行时。

用法：
  python tools/contentc.py --content content --content mods --out build/content.pack.json --report
  python tools/contentc.py --content content --docs build/components.md
"""

from __future__ import annotations

import argparse
import copy
import fnmatch
import json
import sys
import tomllib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from contract.registry import (  # noqa: E402
    BRAINS,
    COMPONENTS,
    KINDS,
    LOOT_TABLES,
    MESHES,
    PALETTES,
    SUPPORTED_API,
    check_value,
)

ALLOWED_TOP = {"api_version", "id", "kind", "extends", "name", "doc", "tags", "components", "target"}
OPS = ("set", "mul", "add")


@dataclass
class Doc:
    cid: str
    kind: str
    path: Path
    order: int
    raw: dict
    hits: list[str] = field(default_factory=list)


def rel(p: Path) -> str:
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


# --------------------------------------------------------------------------
# 1. 解析
# --------------------------------------------------------------------------


def load_docs(dirs: list[str], errors: list[str]) -> list[Doc]:
    docs: list[Doc] = []
    for order, d in enumerate(dirs):
        base = Path(d)
        if not base.exists():
            errors.append(f"内容目录不存在：{d}")
            continue
        for p in sorted(base.rglob("*.toml")):
            try:
                raw = tomllib.loads(p.read_text(encoding="utf-8"))
            except tomllib.TOMLDecodeError as e:
                errors.append(f"{rel(p)}: TOML 语法错误 —— {e}")
                continue

            kind = raw.get("kind")
            if not isinstance(kind, str):
                errors.append(f"{rel(p)}: 缺少 `kind`")
                continue
            if kind not in KINDS:
                errors.append(f"{rel(p)}: 未知内容类型 `{kind}`（已注册：{', '.join(sorted(KINDS))}）")
                continue

            api = raw.get("api_version")
            if api not in SUPPORTED_API:
                errors.append(
                    f"{rel(p)}: api_version={api!r} 不受支持（当前支持 {sorted(SUPPORTED_API)}）"
                )
                continue

            relpath = p.relative_to(base).with_suffix("")
            cid = raw.get("id") or "/".join(relpath.parts)
            if not isinstance(cid, str) or not cid:
                errors.append(f"{rel(p)}: `id` 非法")
                continue

            for k in raw:
                if k not in ALLOWED_TOP:
                    errors.append(f"{rel(p)}: 未知的顶层字段 `{k}`")

            docs.append(Doc(cid, kind, p, order, raw))
    return docs


# --------------------------------------------------------------------------
# 2. 合成
# --------------------------------------------------------------------------


def deep_merge(base: dict, over: dict) -> dict:
    """父 <- 子。组件按字段级合并，标签取并集，其余整体覆盖。"""
    out = copy.deepcopy(base)
    for k, v in over.items():
        if k == "components":
            comps = out.setdefault("components", {})
            for cname, cval in v.items():
                if not isinstance(cval, dict):
                    comps[cname] = copy.deepcopy(cval)
                    continue
                tgt = comps.setdefault(cname, {})
                if isinstance(tgt, dict):
                    tgt.update(copy.deepcopy(cval))
                else:
                    comps[cname] = copy.deepcopy(cval)
        elif k == "tags":
            out["tags"] = sorted(set(out.get("tags", [])) | set(v or []))
        else:
            out[k] = copy.deepcopy(v)
    return out


def resolve_one(
    cid: str,
    by_id: dict[str, Doc],
    cache: dict[str, dict],
    stack: list[str],
    errors: list[str],
) -> dict:
    if cid in cache:
        return cache[cid]
    if cid in stack:
        errors.append(f"循环继承：{' -> '.join(stack + [cid])}")
        return {"components": {}, "tags": []}

    doc = by_id[cid]
    body = {k: copy.deepcopy(v) for k, v in doc.raw.items() if k not in ("api_version", "kind", "id", "extends")}
    body["kind"] = doc.kind
    body["_source"] = rel(doc.path)

    parent = doc.raw.get("extends")
    if parent is not None:
        if not isinstance(parent, str):
            errors.append(f"{rel(doc.path)}: `extends` 必须是字符串 id")
        elif parent not in by_id:
            errors.append(f"{rel(doc.path)}: extends 指向不存在的 id `{parent}`")
        elif by_id[parent].kind != doc.kind:
            errors.append(
                f"{rel(doc.path)}: extends 的类型不匹配（`{parent}` 是 {by_id[parent].kind}，这里是 {doc.kind}）"
            )
        else:
            pbody = resolve_one(parent, by_id, cache, stack + [cid], errors)
            body = deep_merge(pbody, body)
            body["_source"] = rel(doc.path)

    cache[cid] = body
    return body


def apply_patch(cid: str, body: dict, doc: Doc, errors: list[str]) -> None:
    comps = doc.raw.get("components", {})
    if not isinstance(comps, dict):
        errors.append(f"{rel(doc.path)}: `components` 必须是表")
        return
    if not comps:
        return

    for cname, cval in comps.items():
        if cname not in body.get("components", {}):
            errors.append(f"{rel(doc.path)}: 目标 `{cid}` 没有组件 `{cname}`，无法覆写")
            continue
        spec = COMPONENTS.get(cname)
        if spec is None:
            errors.append(f"{rel(doc.path)}: 未注册的组件 `{cname}`")
            continue
        if not isinstance(cval, dict):
            errors.append(f"{rel(doc.path)}: 组件 `{cname}` 必须是表")
            continue

        target = body["components"][cname]
        for fname, fval in cval.items():
            fspec = spec.fields.get(fname)
            if fspec is None:
                errors.append(f"{rel(doc.path)}: `{cname}` 没有字段 `{fname}`（可用：{', '.join(fspec_names(spec))}）")
                continue
            cur = target.get(fname, fspec.default)
            if isinstance(fval, dict):
                for op, arg in fval.items():
                    if op not in OPS:
                        errors.append(f"{rel(doc.path)}: 未知操作 `{op}`（可用：{', '.join(OPS)}）")
                        continue
                    if op == "set":
                        cur = arg
                    elif op == "mul":
                        cur = cur * arg
                    else:
                        cur = cur + arg
            else:
                cur = fval

            # 整数字段被 mul / add 之后会变成小数，这里显式取整，
            # 而不是让运行时去猜 —— 猜错的代价是平衡崩了还查不出来。
            if fspec.type == "int" and isinstance(cur, float) and not isinstance(cur, bool):
                cur = int(round(cur))
            elif fspec.type == "float" and isinstance(cur, int) and not isinstance(cur, bool):
                cur = float(cur)
            target[fname] = cur

    tags = doc.raw.get("tags")
    if tags:
        body["tags"] = sorted(set(body.get("tags", [])) | set(tags))

    warn = doc.raw.get("warn")
    if warn:
        body.setdefault("_patched_by", []).append(f"{rel(doc.path)}: {warn}")


def fspec_names(spec) -> list[str]:
    return sorted(spec.fields)


# --------------------------------------------------------------------------
# 3. 校验
# --------------------------------------------------------------------------


def validate(cid: str, body: dict, errors: list[str]) -> None:
    src = body.get("_source", cid)
    for req in KINDS[body["kind"]].require:
        if req not in body or body[req] in (None, ""):
            errors.append(f"{src}: `{cid}` 缺少必填字段 `{req}`")

    comps = body.get("components")
    if comps is None:
        comps = {}
        body["components"] = comps
    if not isinstance(comps, dict):
        errors.append(f"{src}: `{cid}` 的 components 必须是表")
        return

    for cname, cval in comps.items():
        spec = COMPONENTS.get(cname)
        if spec is None:
            errors.append(f"{src}: `{cid}` 使用了未注册的组件 `{cname}`（已注册：{', '.join(sorted(COMPONENTS))}）")
            continue
        if not isinstance(cval, dict):
            errors.append(f"{src}: `{cid}.{cname}` 必须是表")
            continue

        for fname, fval in list(cval.items()):
            fspec = spec.fields.get(fname)
            if fspec is None:
                errors.append(
                    f"{src}: `{cid}.{cname}` 有未知字段 `{fname}`（可用：{', '.join(fspec_names(spec))}）"
                )
                continue
            problem = check_value(fspec, fval)
            if problem:
                errors.append(f"{src}: `{cid}.{cname}.{fname}` {problem}")
            elif fspec.type == "float" and isinstance(fval, int) and not isinstance(fval, bool):
                cval[fname] = float(fval)

        for fname, fspec in spec.fields.items():
            if fname not in cval:
                cval[fname] = fspec.default


def semantic_checks(resolved: dict[str, dict], errors: list[str], warnings: list[str]) -> None:
    for cid, body in resolved.items():
        src = body.get("_source", cid)
        comps = body.get("components", {})

        model = comps.get("model")
        if model and model.get("mesh") not in MESHES:
            errors.append(f"{src}: `{cid}` 引用了未注册的网格 `{model.get('mesh')}`")

        spawner = comps.get("spawner")
        if spawner:
            target = spawner.get("archetype")
            if target:
                if target not in resolved:
                    errors.append(f"{src}: `{cid}.spawner.archetype` 指向不存在的 id `{target}`")
                elif resolved[target]["kind"] != "archetype":
                    errors.append(f"{src}: `{cid}.spawner.archetype` 指向的不是 archetype（`{target}`）")

        if body["kind"] == "room" and "room" not in comps:
            errors.append(f"{src}: room 类型必须带 `room` 组件")

        if body["kind"] == "item" and not ({"pickup", "wieldable"} & set(comps)):
            warnings.append(f"{src}: 物品 `{cid}` 既不可拾取也不可持握，可能永远不会出现")

        if "ai" in comps and "move" not in comps:
            warnings.append(f"{src}: `{cid}` 有 ai 但没有 move，它不会动")

        if "light" in comps and not comps["light"].get("flicker"):
            pass


# --------------------------------------------------------------------------
# 4. 打包
# --------------------------------------------------------------------------


def build_schema() -> dict:
    """把契约层导出成数据，跟内容包一起走。

    引擎侧靠它回答一个问题：「内容里用到的组件，我实现了几个？」
    缺口从此可见，而不是等某个字段被静默忽略三个月。

    这不是第二份真相：schema 永远由 contract/registry.py 生成，
    手改会被下一次 check.sh 覆盖。真相只有 registry.py 一处。
    """
    components: dict[str, dict] = {}
    for name in sorted(COMPONENTS):
        spec = COMPONENTS[name]
        fields: dict[str, dict] = {}
        for fname in sorted(spec.fields):
            fd = spec.fields[fname]
            fields[fname] = {
                "type": fd.type,
                "default": fd.default,
                "min": fd.min,
                "max": fd.max,
                "enum": list(fd.enum) if fd.enum else None,
            }
        components[name] = {"doc": spec.doc, "fields": fields}

    return {
        "components": components,
        "kinds": {
            n: {"doc": KINDS[n].doc, "require": list(KINDS[n].require)} for n in sorted(KINDS)
        },
        "brains": list(BRAINS),
        "loot_tables": list(LOOT_TABLES),
        "meshes": dict(MESHES),
        "palettes": {n: list(c) for n, c in sorted(PALETTES.items())},
    }


def build_pack(dirs: list[str]) -> tuple[dict, list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []

    docs = load_docs(dirs, errors)

    by_id: dict[str, Doc] = {}
    patches: list[Doc] = []
    for d in docs:
        if d.kind == "patch":
            patches.append(d)
        elif d.cid in by_id:
            errors.append(
                f"id 冲突：`{d.cid}` 同时出现在 {rel(by_id[d.cid].path)} 和 {rel(d.path)}"
                "（想覆写请用 kind=\"patch\"）"
            )
        else:
            by_id[d.cid] = d

    cache: dict[str, dict] = {}
    resolved: dict[str, dict] = {}
    for cid in by_id:
        resolved[cid] = resolve_one(cid, by_id, cache, [], errors)

    patches.sort(key=lambda d: (d.order, str(d.path)))
    for doc in patches:
        tgt = doc.raw.get("target")
        if not isinstance(tgt, str) or not tgt:
            errors.append(f"{rel(doc.path)}: patch 必须有 `target`")
            continue
        matched = [cid for cid in resolved if fnmatch.fnmatchcase(cid, tgt)]
        if not matched:
            warnings.append(f"{rel(doc.path)}: target `{tgt}` 没有匹配到任何内容，这个 mod 是空操作")
        for cid in matched:
            apply_patch(cid, resolved[cid], doc, errors)
            doc.hits.append(cid)

    for cid, body in resolved.items():
        validate(cid, body, errors)

    semantic_checks(resolved, errors, warnings)

    counts: dict[str, int] = {}
    for body in resolved.values():
        counts[body["kind"]] = counts.get(body["kind"], 0) + 1

    pack = {
        "api_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": dirs,
        "schema": build_schema(),
        "counts": counts,
        "entities": {cid: resolved[cid] for cid in sorted(resolved)},
        "warnings": warnings,
        "patch_summary": [{"file": rel(d.path), "target": d.raw.get("target"), "hits": d.hits} for d in patches],
    }
    return pack, errors, warnings


def emit_docs(path: Path) -> None:
    lines = ["# 组件参考（自动生成，勿手改）", "", f"由 contract/registry.py 生成，共 {len(COMPONENTS)} 个组件。", ""]
    for name in sorted(COMPONENTS):
        spec = COMPONENTS[name]
        lines.append(f"## `{name}`")
        lines.append("")
        lines.append(spec.doc)
        lines.append("")
        lines.append("| 字段 | 类型 | 默认 | 范围 / 枚举 | 说明 |")
        lines.append("|---|---|---|---|---|")
        for fname in spec.fields:
            f = spec.fields[fname]
            rng = ""
            if f.enum:
                rng = ", ".join(f.enum)
            elif f.min is not None or f.max is not None:
                rng = f"{f.min if f.min is not None else '-∞'} ~ {f.max if f.max is not None else '∞'}"
            lines.append(f"| `{fname}` | {f.type} | `{f.default}` | {rng} | {f.doc} |")
        lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"组件文档 -> {rel(path)}")


def emit_binary(pack: dict, path: Path, quiet: bool = False) -> None:
    """打包成扁平二进制，给 C++ 运行时用。

    为什么不用 JSON：JSON 要建 3 万个字典再逐个查表，启动就是几百毫秒；
    这个格式读进来就是一段连续内存，全部实体一次 memcpy 到位。
    字段顺序和数量是**格式契约**，改了就要升 version，老存档才不会被误读。
    """
    import struct

    from contract.registry import MESHES

    ents = pack["entities"]
    mesh_names = sorted(MESHES)
    mesh_idx = {n: i for i, n in enumerate(mesh_names)}

    pals = sorted({b["components"]["model"]["palette"]
                   for b in ents.values()
                   if "model" in b.get("components", {})})
    pal_idx = {n: i for i, n in enumerate(pals)}
    kinds = ["archetype", "item", "room", "patch"]

    out = bytearray()
    out += b"CGPK" + struct.pack("<I", 2)

    out += struct.pack("<I", len(mesh_names))
    for n in mesh_names:
        nb = n.encode()
        out += struct.pack("<H", len(nb)) + nb + struct.pack("<I", MESHES[n])

    out += struct.pack("<I", len(pals))
    for n in pals:
        nb = n.encode()
        out += struct.pack("<H", len(nb)) + nb

    rows = []
    for cid, body in ents.items():
        comps = body.get("components", {})
        m = comps.get("model")
        # 只有"有外观的 archetype"会被摆进世界；纯模板和道具不进
        if body.get("kind") != "archetype" or m is None:
            continue
        tr = comps.get("transform", {})
        li = comps.get("light")
        mv = comps.get("move", {})
        ai = comps.get("ai", {})
        rows.append((
            cid, kinds.index(body["kind"]) if body.get("kind") in kinds else 0,
            mesh_idx[m["mesh"]], pal_idx[m["palette"]],
            float(tr.get("scale", 1.0)), float(tr.get("yaw", 0.0)),
            1 if (li and li.get("intensity", 0.0) > 0.0) else 0,
            float(li.get("radius", 6.0)) if li else 0.0,
            float(li.get("intensity", 0.0)) if li else 0.0,
            float(mv.get("speed", 0.0)),
            float(ai.get("aggro_radius", 0.0)),
        ))

    out += struct.pack("<I", len(rows))
    for (cid, ki, mi, pi, sc, yaw, lit, lr, lint_, spd, aggro) in rows:
        cb = cid.encode()
        out += struct.pack("<H", len(cb)) + cb
        out += struct.pack("<BBH", ki, mi, pi)
        out += struct.pack("<ffffff", sc, yaw, lr, lint_, spd, aggro)
        out += struct.pack("<B", lit)

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(out))
    if not quiet:
        print(f"二进制 -> {rel(path)}  ({len(out) / 1024:.1f} KB, {len(rows)} 个可摆放原型)")


def main() -> int:
    ap = argparse.ArgumentParser(description="内容编译器")
    ap.add_argument("--content", action="append", required=True, help="内容目录，可多次指定，顺序即加载顺序（后者覆盖前者）")
    ap.add_argument("--out", default="build/content.pack.json")
    ap.add_argument("--bin", default=None, help="顺带输出给 C++ 运行时读的二进制包")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--docs", default=None, help="顺带生成组件参考文档")
    args = ap.parse_args()

    pack, errors, warnings = build_pack(args.content)

    if args.docs:
        emit_docs(Path(args.docs))

    if errors:
        print(f"\n编译失败，{len(errors)} 个问题：\n", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        print("\n没有产出 pack。修好再来。", file=sys.stderr)
        return 1

    out = Path(args.out)
    if not out.is_absolute():
        out = ROOT / out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(pack, ensure_ascii=False, indent=1), encoding="utf-8")

    if args.bin:
        bp = Path(args.bin)
        if not bp.is_absolute():
            bp = ROOT / bp
        emit_binary(pack, bp)

    if args.report:
        print("内容编译")
        for i, d in enumerate(pack["sources"]):
            n = len(list(Path(d).rglob("*.toml"))) if Path(d).exists() else 0
            print(f"  {i}  {d:<24} {n} 个文件")
        print()
        print(f"实体 {sum(pack['counts'].values())} 个")
        for k, v in sorted(pack["counts"].items()):
            print(f"  {k:<12} {v}")
        usage: dict[str, int] = {}
        for body in pack["entities"].values():
            for c in body.get("components", {}):
                usage[c] = usage.get(c, 0) + 1
        print("\n组件使用")
        for k, v in sorted(usage.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  {k:<12} {v}")
        if pack["patch_summary"]:
            print("\npatch")
            for p in pack["patch_summary"]:
                print(f"  {p['file']}  ->  {p['target']}  ({len(p['hits'])} 个目标)")
        if warnings:
            print(f"\n警告 {len(warnings)} 条")
            for w in warnings:
                print(f"  ! {w}")
        size = out.stat().st_size
        print(f"\n打包 -> {rel(out)}  ({size / 1024:.1f} KB)")
    else:
        print(f"OK  {sum(pack['counts'].values())} 个实体 -> {rel(out)}")
        if warnings:
            print(f"    {len(warnings)} 条警告（--report 查看）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
