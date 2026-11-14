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
import re
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
    HOOKS,
    KINDS,
    MESHES,
    MOD_LEVELS,
    PALETTES,
    SUPPORTED_API,
    TOP_FIELDS,
    Field,
    check_value,
)

OPS = ("set", "mul", "add")

## mod.toml 的 [mod] 段允许哪些字段。
## 白名单而不是黑名单：把 `levle` 拼错成 data 会让授权保护静默失效，
## 而拼错字段名是 mod 开发里最高的错误率来源之一。
ALLOWED_MOD = {"id", "name", "version", "api_version", "level", "author", "description"}
MOD_REQUIRED = ("id", "name", "version", "api_version", "level")
## mod id 会成为目录名、存档键、日志前缀，所以只允许扁平的 ASCII。
MOD_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{1,31}$")


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

            for k, v in raw.items():
                t = TOP_FIELDS.get(k)
                if t is None:
                    errors.append(
                        f"{rel(p)}: 未知的顶层字段 `{k}`"
                        f"（契约里有：{', '.join(sorted(TOP_FIELDS))}）"
                    )
                    continue
                # 类型也要查。`abstract = "true"`（带引号）是一个字符串，
                # 在 Python 里是真值，在 GDScript 里却是真值 —— 于是它"碰巧能用"，
                # 直到某天有人把它读成 bool。这种情况必须当场拒绝。
                problem = check_value(Field(t), v)
                if problem:
                    errors.append(f"{rel(p)}: 顶层字段 `{k}` {problem}")

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

    # abstract **不继承**。它回答的是"这条内容本身能不能单独存在"，
    # 而 extends 出来的是**另一条**内容，默认就该能存在。
    #
    # 如果让它跟着继承，给基类标一个 abstract 会连带把它的所有子类变成模板：
    # 房间里那一整类东西会静默消失，而且编译期、运行期都不报错。
    # 这是"抽象"这个词在继承体系里最容易搞反的一处，所以显式写出来。
    if "abstract" not in doc.raw:
        body.pop("abstract", None)

    cache[cid] = body
    return body


def apply_patch(cid: str, body: dict, doc: Doc, errors: list[str]) -> None:
    # `abstract` 不在 patch 能改的范围内。patch 的语义是"改一个已有东西的数值"，
    # 而 abstract 决定"这东西还能不能存在"—— 通过 patch 把一个具体内容变成模板，
    # 等于在玩家装了一个 mod 之后，世界里静默地少掉一整类东西。
    if "abstract" in doc.raw:
        errors.append(
            f"{rel(doc.path)}: patch 不能改 `abstract`"
            "（它决定目标能不能存在；要藏内容请直接改那一份内容）"
        )
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


def semantic_checks(
    resolved: dict[str, dict],
    errors: list[str],
    warnings: list[str],
    extended: set[str] | None = None,
) -> None:
    """跨内容的检查。单个文件自己看不出问题的地方，全在这里看。

    extended：被谁 extends 过的 id 集合。用来发现"写了基类但没人继承"——
    那通常意味着子类那边 `extends` 写错了名字，或者基类是复制粘贴的残留。
    """
    parents = extended or set()
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
                elif resolved[target].get("abstract"):
                    # 抽象基类的数据通常是不完整的（比如它故意不给 model，
                    # 让子类各给各的）。把它填进房间的结果是一个半成品站在那儿，
                    # 或者干脆一片空白 —— 两种都不会报错。
                    errors.append(
                        f"{src}: `{cid}.spawner.archetype` 指向抽象基类 `{target}`"
                        "（它只能被 extends，不能直接摆进世界）"
                    )

        loot = comps.get("loot")
        if loot and loot.get("table"):
            target = loot.get("table")
            if target not in resolved:
                errors.append(f"{src}: `{cid}.loot.table` 指向不存在的 id `{target}`")
            elif resolved[target]["kind"] != "loot_table":
                errors.append(
                    f"{src}: `{cid}.loot.table` 指向的不是 loot_table（`{target}`）"
                )

        if body["kind"] == "loot_table":
            entries = body.get("entries", [])
            if not isinstance(entries, list):
                errors.append(f"{src}: loot_table `{cid}` 的 entries 必须是列表")
            else:
                for i, ent in enumerate(entries):
                    if not isinstance(ent, dict):
                        errors.append(f"{src}: `{cid}.entries[{i}]` 必须是一张表")
                        continue
                    drop = ent.get("id", "")
                    if not drop:
                        errors.append(f"{src}: `{cid}.entries[{i}]` 缺 id")
                    elif drop not in resolved:
                        errors.append(
                            f"{src}: `{cid}.entries[{i}]` 指向不存在的 id `{drop}`"
                        )
                    elif resolved[drop]["kind"] != "item":
                        errors.append(
                            f"{src}: `{cid}.entries[{i}]` 掉的东西不是 item（`{drop}`）"
                        )
                    ch = ent.get("chance", None)
                    if not isinstance(ch, (int, float)) or not (0.0 <= float(ch) <= 1.0):
                        errors.append(
                            f"{src}: `{cid}.entries[{i}].chance` 必须是 0 到 1 的数"
                        )

        if body["kind"] == "room" and "room" not in comps:
            errors.append(f"{src}: room 类型必须带 `room` 组件")

        if body["kind"] == "item" and not ({"pickup", "wieldable"} & set(comps)):
            warnings.append(f"{src}: 物品 `{cid}` 既不可拾取也不可持握，可能永远不会出现")

        if "ai" in comps and "move" not in comps:
            warnings.append(f"{src}: `{cid}` 有 ai 但没有 move，它不会动")

        if body.get("abstract") and cid not in parents:
            warnings.append(
                f"{src}: `{cid}` 标了 abstract，但没有任何内容 extends 它"
                "（它是死内容；如果是基类，检查子类的 extends 是不是写错了名字）"
            )

        if "light" in comps and not comps["light"].get("flicker"):
            pass


def check_scripts(
    resolved: dict[str, dict],
    errors: list[str],
    warnings: list[str],
    script_root: Path | None = None,
) -> None:
    """行为 mod 的静态检查。

    运行时编译意味着"写错了"要到游戏跑起来才知道 —— 而 mod 作者可能根本不开游戏，
    只改了 TOML。所以能在编译期抓住的错，一律在这里抓住：

      * 源码文件存不存在（最常见：路径写错、忘了把 .gd 一起拷进来）
      * 声明的事件在不在契约里（拼错一个字母，那个钩子就永远不会触发，且毫无提示）
      * 文件里有没有 `func handle(` —— 没有入口函数，加载器只会静默跳过

    第三条是文本匹配，看着粗糙，但它挡掉的是 mod 开发里最高频的错误，
    而且比启动一次引擎便宜三个数量级。

    script_root：源码路径相对于谁。基础内容是仓库根；mod 是自己的目录
    （mod 是可独立发布的单元，它不该知道仓库长什么样）。
    """
    root = script_root if script_root is not None else ROOT
    seen_hooks: dict[str, str] = {}

    for cid, body in resolved.items():
        if body.get("kind") != "script":
            continue
        src = body.get("_source", cid)
        source = body.get("source")
        events = body.get("events")

        if not isinstance(source, str) or not source.endswith(".gd"):
            errors.append(f"{src}: `source` 必须是 .gd 文件路径")
            continue
        path = Path(source) if Path(source).is_absolute() else root / source
        if not path.exists():
            errors.append(f"{src}: 找不到脚本 `{source}`（找的是 {path}）")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if "func handle(" not in text:
            errors.append(f"{src}: `{source}` 里没有 `func handle(event, ctx, api)`，加载器无法调用它")

        if not isinstance(events, list) or not events:
            errors.append(f"{src}: `events` 必须是非空数组（否则这个 mod 挂了也不会被调用）")
            continue
        for e in events:
            if not isinstance(e, str):
                errors.append(f"{src}: `events` 里出现非字符串 {e!r}")
                continue
            if e not in HOOKS:
                errors.append(
                    f"{src}: 钩子 `{e}` 未注册（已注册：{', '.join(sorted(HOOKS))}）"
                )
                continue
            if e in seen_hooks:
                warnings.append(
                    f"{src}: 钩子 `{e}` 已经由 `{seen_hooks[e]}` 挂载，两个 mod 会同时收到"
                )
            else:
                seen_hooks[e] = cid


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
        "top_fields": dict(TOP_FIELDS),
        "kinds": {
            n: {"doc": KINDS[n].doc, "require": list(KINDS[n].require)} for n in sorted(KINDS)
        },
        "brains": list(BRAINS),
        "meshes": dict(MESHES),
        "palettes": {n: list(c) for n, c in sorted(PALETTES.items())},
        "hooks": {
            n: {
                "doc": HOOKS[n].doc,
                "params": list(HOOKS[n].params),
                "returns": list(HOOKS[n].returns),
                "blocking": HOOKS[n].blocking,
            }
            for n in sorted(HOOKS)
        },
    }


def build_pack(
    dirs: list[str], script_root: Path | None = None
) -> tuple[dict, list[str], list[str]]:
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

    extended = {
        d.raw["extends"]
        for d in by_id.values()
        if isinstance(d.raw.get("extends"), str)
    }
    semantic_checks(resolved, errors, warnings, extended)
    check_scripts(resolved, errors, warnings, script_root)

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


# --------------------------------------------------------------------------
# 5. mod 编译
# --------------------------------------------------------------------------


def _public(body: dict) -> dict:
    """去掉编译器的内部字段（`_source` 之类），用来比较两份实体是否等价。

    内部字段带的是本机路径，跨机器、跨目录都会变 —— 拿它参与比较会让
    "内容没改"被误判成"改了"，产出的 diff 里全是噪音。
    """
    return {k: v for k, v in body.items() if not k.startswith("_")}


def build_mod(
    mod_dir: Path, base_dirs: list[str] | None = None
) -> tuple[dict | None, list[str], list[str]]:
    """把一个 mod 目录编译成一个自包含的运行时产物。

    mod 是**可独立发布的单元**：一个目录，拷进去就能用，不依赖仓库里的别的东西。
    所以它有自己的一步编译，产物落在 `content.pack.json`，引擎只读那个文件。

    为什么不让引擎直接读 mod 的 TOML：那等于在引擎里再写一个 TOML 解析器，
    于是有两份编译器、两套行为，迟早不一致。作者写 TOML（人手舒服），
    产物是 JSON（机器原生），中间那层永远只有 Python 这一份。

    **patch 型 mod 需要 base**：`kind="patch"` 的语义是"作用在已解析完继承链的
    实体上"，所以它必须能看见基线内容。这里把 base 编译一遍、把 mod 编译一遍，
    然后把两者的差异作为产物 —— 于是 mod 的产物永远是"它改变了什么"，
    而不是"它抄了一份整个世界"。也正因此，多个 mod 可以叠加。
    """
    errors: list[str] = []
    warnings: list[str] = []

    manifest = mod_dir / "mod.toml"
    if not manifest.exists():
        return None, [f"{rel(mod_dir)}: 缺少 mod.toml（一个 mod 最少要有它）"], warnings
    try:
        raw = tomllib.loads(manifest.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        return None, [f"{rel(manifest)}: TOML 解析失败 —— {e}"], warnings

    meta = raw.get("mod")
    if not isinstance(meta, dict):
        return None, [f"{rel(manifest)}: 必须有 [mod] 段"], warnings

    for k in sorted(meta):
        if k not in ALLOWED_MOD:
            errors.append(
                f"{rel(manifest)}: [mod] 里不认识 `{k}`"
                f"（允许：{', '.join(sorted(ALLOWED_MOD))}）"
            )
    for k in MOD_REQUIRED:
        if k not in meta:
            errors.append(f"{rel(manifest)}: [mod] 缺字段 `{k}`")

    mid = str(meta.get("id", ""))
    if not MOD_ID_RE.match(mid):
        errors.append(
            f"{rel(manifest)}: id `{mid}` 不合法（小写字母或数字开头，可含 - _，2-32 字符）"
        )
    elif mid != mod_dir.name:
        warnings.append(
            f"{rel(manifest)}: id `{mid}` 与目录名 `{mod_dir.name}` 不同"
            "（允许，但装进 mods/ 之后不容易找）"
        )

    api = meta.get("api_version")
    if api not in SUPPORTED_API:
        errors.append(
            f"{rel(manifest)}: api_version {api!r} 不在支持范围 {sorted(SUPPORTED_API)} —— "
            "这个 mod 是给别的版本写的"
        )

    declared = str(meta.get("level", ""))
    if declared not in MOD_LEVELS:
        errors.append(
            f"{rel(manifest)}: level `{declared}` 不合法（允许：{', '.join(sorted(MOD_LEVELS))}）"
        )

    content_dir = mod_dir / "content"
    base = [d for d in (base_dirs or []) if Path(d).is_dir()]
    if content_dir.is_dir():
        inputs = base + [str(content_dir)]
        pack, e, w = build_pack(inputs, script_root=mod_dir)
    else:
        pack = {"counts": {}, "entities": {}, "warnings": []}
        e, w = [], []
        warnings.append(f"{rel(mod_dir)}: 没有 content/ 目录，这个 mod 不添加任何内容")
    errors += e
    warnings += w

    # 只留下"这个 mod 改变了什么"。基线编译的结果里可能有它自己的错误
    # （内容层坏了会先在 check.sh 第 1 步报出来），这里不再重复报。
    changed: dict[str, dict] = {}
    if base:
        baseline, _, _ = build_pack(base)
        for cid, body in pack["entities"].items():
            old = baseline["entities"].get(cid)
            if old is None or _public(old) != _public(body):
                changed[cid] = body
    else:
        changed = dict(pack["entities"])
    pack["entities"] = changed
    # counts 必须按 diff 重算，不能沿用全量那份 —— 否则一个只改了两个敌人的
    # mod 会声称自己带了几百条内容，而"内容量"是这个项目所有预算判断的分子。
    counts: dict[str, int] = {}
    for body in changed.values():
        counts[body["kind"]] = counts.get(body["kind"], 0) + 1
    pack["counts"] = counts

    script_ids = [cid for cid, b in changed.items() if b.get("kind") == "script"]
    scripts_dir = mod_dir / "scripts"
    has_gd = scripts_dir.is_dir() and any(scripts_dir.rglob("*.gd"))

    # **实际级别由"有没有可执行代码"决定，不由作者声明决定。**
    # 作者完全可以把带脚本的 mod 写成 level="data" 来绕过玩家授权 ——
    # 如果引擎相信声明，那道授权闸门就是纸做的。所以这里算一遍真实的，
    # 引擎侧还会再独立算一遍（不信任产物，产物也可能被手改）。
    actual = "script" if (script_ids or has_gd) else "data"
    if declared == "data" and actual == "script":
        warnings.append(
            f"{rel(manifest)}: 声明 data 级但带了脚本，按 script 级处理"
            "（否则声明就成了绕过授权的办法）"
        )
    if declared == "script" and actual == "data":
        warnings.append(f"{rel(manifest)}: 声明 script 级但没有脚本，按 data 级处理")
    if has_gd and not script_ids:
        warnings.append(
            f"{rel(mod_dir)}: scripts/ 下有 .gd，但内容里没有任何 kind=\"script\" 绑定 —— "
            "这些脚本永远不会被加载"
        )

    if errors:
        return None, errors, warnings

    product = {
        "api_version": 1,
        "mod": {
            "id": mid,
            "name": str(meta.get("name", mid)),
            "version": str(meta.get("version", "0.0.0")),
            "author": str(meta.get("author", "")),
            "description": str(meta.get("description", "")),
            "level": actual,
            "declared_level": declared,
        },
        "counts": pack["counts"],
        "entities": pack["entities"],
        "warnings": pack["warnings"],
    }
    return product, errors, warnings


def compile_one_mod(mod_dir: Path, base_dirs: list[str] | None = None) -> int:
    if not mod_dir.is_absolute():
        mod_dir = (Path.cwd() / mod_dir).resolve()
    product, errors, warnings = build_mod(mod_dir, base_dirs)
    name = mod_dir.name

    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    if errors or product is None:
        print(f"\nmod `{name}` 编译失败，{len(errors)} 个问题：\n", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        print("\n没有产出 content.pack.json。修好再来。", file=sys.stderr)
        return 1

    out = mod_dir / "content.pack.json"
    out.write_text(json.dumps(product, ensure_ascii=False, indent=1), encoding="utf-8")
    meta = product["mod"]
    print(
        f"OK  mod `{meta['id']}` v{meta['version']} [{meta['level']}]  "
        f"{sum(product['counts'].values())} 条 -> {rel(out)}"
    )
    return 0


# --------------------------------------------------------------------------
# 6. 编译器自测
# --------------------------------------------------------------------------


SELFTEST_FILES: dict[str, dict[str, str]] = {
    "abstract 不继承": {
        "base.toml": """
api_version = 1
kind = "archetype"
id = "t/base"
name = "基类"
abstract = true
[components.model]
mesh = "prop_crate"
""",
        "child.toml": """
api_version = 1
kind = "archetype"
id = "t/child"
extends = "t/base"
name = "子类"
""",
    },
    "抽象不能被 spawner 指向": {
        "base.toml": """
api_version = 1
kind = "archetype"
id = "t/base"
name = "基类"
abstract = true
[components.model]
mesh = "prop_crate"
""",
        "room.toml": """
api_version = 1
kind = "room"
id = "t/room"
name = "房间"
[components.room]
size_x = 10.0
size_z = 10.0
[components.spawner]
archetype = "t/base"
count = 2
""",
    },
    "顶层字段拼错": {
        "bad.toml": """
api_version = 1
kind = "archetype"
id = "t/bad"
name = "拼错"
abstact = true
""",
    },
    "顶层字段类型错": {
        "bad.toml": """
api_version = 1
kind = "archetype"
id = "t/bad"
name = "类型错"
abstract = "true"
""",
    },
    "patch 不能改 abstract": {
        "crate.toml": """
api_version = 1
kind = "archetype"
id = "t/crate"
name = "箱子"
[components.model]
mesh = "prop_crate"
""",
        "patch.toml": """
api_version = 1
kind = "patch"
target = "t/*"
abstract = true
""",
    },
    "掉落表悬空引用": {
        "enemy.toml": """
api_version = 1
kind = "archetype"
id = "t/enemy"
name = "怪"
[components.model]
mesh = "prop_crate"
[components.loot]
table = "t/nope"
chance = 1.0
""",
    },
    "掉落条目悬空": {
        "table.toml": """
api_version = 1
kind = "loot_table"
id = "t/table"
name = "表"
entries = [
  { id = "t/nothing", chance = 0.5 },
]
""",
    },
}

## 每个场景"必须出现"的一段错误文本。空 = 必须编译通过。
SELFTEST_EXPECT: dict[str, str] = {
    "abstract 不继承": "",
    "抽象不能被 spawner 指向": "抽象基类",
    "顶层字段拼错": "未知的顶层字段 `abstact`",
    "顶层字段类型错": "顶层字段 `abstract` 期望 true / false",
    "patch 不能改 abstract": "patch 不能改 `abstract`",
    "掉落表悬空引用": "指向不存在的 id `t/nope`",
    "掉落条目悬空": "指向不存在的 id `t/nothing`",
}


def selftest() -> int:
    """编译器自己的验收：拿几个**故意写坏**的小内容，确认它真的会拒绝。

    理由和 lint_arch.py --selftest 一样：一个从来没抓到过东西的检查器，
    和不存在没有区别 —— 而且更危险，因为它看起来是绿的。

    这里特别盯住 `abstract` 的三条规则，因为它们的错法都是"静默"：
    继承错了 = 一整类内容消失；拼错了 = 基类被当实体摆出来；
    patch 能改 = 玩家装个 mod 之后世界上少一半东西。三种都不报错。
    """
    import tempfile

    failed = 0
    for name, files in SELFTEST_FILES.items():
        want = SELFTEST_EXPECT[name]
        with tempfile.TemporaryDirectory() as td:
            for fname, text in files.items():
                Path(td, fname).write_text(text.strip() + "\n", encoding="utf-8")
            pack, errors, _warnings = build_pack([td])

        joined = "\n".join(errors)
        if want and want not in joined:
            print(f"  ✗ {name}：期望报错包含「{want}」，实际 {errors or '没有报错'}", file=sys.stderr)
            failed += 1
            continue
        if not want and errors:
            print(f"  ✗ {name}：不该报错，实际 {errors}", file=sys.stderr)
            failed += 1
            continue

        # 第一条规则还要看结果：子类必须**不带** abstract，否则它会从世界里消失。
        if name == "abstract 不继承":
            base = pack["entities"].get("t/base", {})
            child = pack["entities"].get("t/child", {})
            if not base.get("abstract"):
                print("  ✗ abstract 不继承：基类自己没保留 abstract", file=sys.stderr)
                failed += 1
                continue
            if child.get("abstract"):
                print("  ✗ abstract 不继承：子类被继承成了模板（那一类内容会从世界里消失）", file=sys.stderr)
                failed += 1
                continue

        print(f"  · {name}：符合预期")

    if failed:
        print(f"\n编译器自测失败：{failed} / {len(SELFTEST_FILES)} 条", file=sys.stderr)
        return 1
    print(f"编译器自测通过：{len(SELFTEST_FILES)} 条规则都能抓到违规")
    return 0


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
        # 只有"有外观的具体 archetype"会被摆进世界；纯模板和道具不进
        if body.get("kind") != "archetype" or m is None or body.get("abstract"):
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
    ap.add_argument("--content", action="append", default=None, help="内容目录，可多次指定，顺序即加载顺序（后者覆盖前者）")
    ap.add_argument("--mod", default=None, help="编译单个 mod 目录：读 mod.toml + content/，产出 <dir>/content.pack.json")
    ap.add_argument("--base", action="append", default=None, help="mod 的基线内容目录（patch 型 mod 需要）。默认 content")
    ap.add_argument("--out", default="build/content.pack.json")
    ap.add_argument("--bin", default=None, help="顺带输出给 C++ 运行时读的二进制包")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--docs", default=None, help="顺带生成组件参考文档")
    ap.add_argument("--selftest", action="store_true", help="用故意写坏的内容验证编译器会拒绝")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.mod and args.content:
        ap.error("--mod 与 --content 不能同时用：mod 有自己的一步编译，产物在它自己的目录里")
    if args.mod:
        base = args.base if args.base else ["content"]
        return compile_one_mod(Path(args.mod), base)
    if not args.content:
        ap.error("要么 --content <dir>（基础内容），要么 --mod <dir>（单个 mod）")

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
