#!/usr/bin/env python3
"""架构纪律检查。

为什么存在：写在 docs 里的纪律，agent 会忘；写进 check.sh 的纪律，agent 绕不过。
这个脚本不发明任何新规则，它只是把 docs/structure.md 与 AGENTS.md 里已经写下的
约束变成会失败的检查。

规则清单（每条都对应文档里的原文，改之前先改文档）：

  R1 禁用目录名          AGENTS.md 铁律 4 / structure.md 五
  R2 单文件 ≤ 400 行     structure.md 二
  R3 每域 ≤ 12 个 .gd    structure.md 二
  R4 引擎层不认内容 id   AGENTS.md 铁律 2  ← 这条是架构的命根子
  R5 依赖方向            structure.md 四
  R6 生成物进版本库      AGENTS.md 六
  R7 运行时编译只有一个入口 ADR 0007 / AGENTS.md 铁律 9

用法：
    python3 tools/lint_arch.py                       # 默认读 build/content.pack.json
    python3 tools/lint_arch.py --pack build/x.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / "game"
SCRIPTS = GAME / "scripts"

# 跳过这些目录：不是我们的代码，或者本身就是生成物 / 归档
SKIP_DIRS = {".git", "build", "tools-bin", "legacy", ".godot", "__pycache__"}

BANNED_DIR_NAMES = {"utils", "helpers", "common", "misc", "base", "temp", "shared", "core"}

MAX_LINES = 400
MAX_FILES_PER_DOMAIN = 12


class Findings:
    def __init__(self) -> None:
        self.items: list[str] = []

    def add(self, rule: str, where: str, msg: str) -> None:
        self.items.append(f"  ✗ [{rule}] {where}: {msg}")

    def empty(self) -> bool:
        return not self.items


def walk_files(root: Path, patterns: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    if not root.exists():
        return out
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        if p.suffix in patterns:
            out.append(p)
    return sorted(out)


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def code_lines(path: Path) -> list[str]:
    """只留代码行，去掉注释部分。

    规则判定的是"代码做了什么"，不是"注释里提到了什么"。
    不这么分，架构说明写在注释里就会被判违规 —— 那等于逼人删掉解释，
    是这套检查最坏的一种副作用。
    """
    out: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        idx = line.find("#")
        out.append(line if idx < 0 else line[:idx])
    return out


# ---------------------------------------------------------------- R1
def check_banned_dirs(f: Findings) -> None:
    for p in ROOT.rglob("*"):
        if not p.is_dir():
            continue
        if any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        if p.name in BANNED_DIR_NAMES:
            f.add("R1", rel(p), f"目录名 `{p.name}` 属于垃圾桶命名（structure.md 五）")


# ---------------------------------------------------------------- R2
def check_file_size(f: Findings, gd_files: list[Path]) -> None:
    for p in gd_files:
        n = len(p.read_text(encoding="utf-8", errors="replace").splitlines())
        if n > MAX_LINES:
            f.add("R2", rel(p), f"{n} 行 > {MAX_LINES} 行上限，按职责拆（structure.md 二）")


# ---------------------------------------------------------------- R3
def check_domain_size(f: Findings) -> None:
    if not SCRIPTS.exists():
        return
    for domain in sorted(SCRIPTS.iterdir()):
        if not domain.is_dir() or domain.name in SKIP_DIRS:
            continue
        gd = sorted(domain.rglob("*.gd"))
        if len(gd) > MAX_FILES_PER_DOMAIN:
            f.add("R3", rel(domain),
                  f"{len(gd)} 个 .gd > {MAX_FILES_PER_DOMAIN} 上限，说明这个域在做两件事")
        for p in gd:
            depth = len(p.relative_to(SCRIPTS).parts)
            if depth > 2:
                f.add("R3", rel(p), f"scripts/ 下超过两层（depth={depth}），先拆域再分目录")


# ---------------------------------------------------------------- R4
def check_engine_knows_content(f: Findings, gd_files: list[Path], pack: Path) -> None:
    """引擎层不许出现具体内容 id 的字面量。

    只匹配完整 id（形如 `enemy/bone_walker`），因为裸名（`crate`）会误伤变量名。
    完整 id 出现在引擎代码里，几乎只有一种解释：这里写了特判。
    """
    if not pack.exists():
        f.add("R4", rel(pack), "找不到内容包，无法核对内容 id（先跑内容编译）")
        return
    try:
        data = json.loads(pack.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        f.add("R4", rel(pack), f"内容包不是合法 JSON：{exc}")
        return

    ids = [i for i in data.get("entities", {}) if "/" in i]
    if not ids:
        return

    hits = 0
    for p in gd_files:
        for line in code_lines(p):
            for cid in ids:
                if f'"{cid}"' in line or f"'{cid}'" in line:
                    f.add("R4", rel(p), f"硬编码了内容 id `{cid}` —— 引擎不许认识具体内容（铁律 2）")
                    hits += 1
    if hits:
        return


# ---------------------------------------------------------------- R5
def check_dependency_direction(f: Findings, gd_files: list[Path]) -> None:
    for p in gd_files:
        for line in code_lines(p):
            if "contract/" in line or "contract\\" in line:
                f.add("R5", rel(p), "game/ 里引用了 contract/（Python 契约层）。"
                                    "引擎认的是数据格式，不是 Python 代码（structure.md 四）")
                break

    for p in walk_files(ROOT / "tools", (".py",)):
        if p.name == "lint_arch.py":
            continue
        text = "\n".join(code_lines(p))
        if re.search(r"^\s*(import|from)\s+game\b", text, re.MULTILINE):
            f.add("R5", rel(p), "tools/ 反向依赖 game/（structure.md 四）")


# ---------------------------------------------------------------- R6
def check_generated_in_vcs(f: Findings) -> None:
    try:
        out = subprocess.run(
            ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return  # 不是 git 仓库就跳过，不当成失败
    tracked = set(out.splitlines())
    for bad in ("game/content.pack.json", "build/content.pack.json", "build/content.pack.bin"):
        if bad in tracked:
            f.add("R6", bad, "生成物被提交进版本库，应由 ./check.sh 生成并 gitignore")


# ---------------------------------------------------------------- R7
def check_single_mod_entry(f: Findings, gd_files: list[Path]) -> None:
    """运行时编译 GDScript 的能力只能有一个入口：`scripts/mods/`。

    这是整个引擎里唯一"能凭空造出代码"的地方。它散落到第二个文件，
    就等于多了一个从外部注入代码的路径，而且是没人审查过的那条。
    将来做 mod 授权 UI，只需要守这一个点。
    """
    allow_dir = SCRIPTS / "mods"
    for p in gd_files:
        if allow_dir in p.parents:
            continue
        for line in code_lines(p):
            if "GDScript.new(" in line:
                f.add("R7", rel(p), "只有 scripts/mods/ 可以运行时编译 GDScript"
                                    "（ADR 0007：代码注入点必须只有一个）")
                break


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", default="build/content.pack.json")
    ap.add_argument("--selftest", action="store_true",
                    help="造一批违规，确认每条规则真的会触发（检查器本身也要被检查）")
    args = ap.parse_args()

    if args.selftest:
        return run_selftest()

    gd_files = walk_files(GAME, (".gd",))
    f = Findings()

    check_banned_dirs(f)
    check_file_size(f, gd_files)
    check_domain_size(f)
    check_engine_knows_content(f, gd_files, ROOT / args.pack)
    check_dependency_direction(f, gd_files)
    check_generated_in_vcs(f)
    check_single_mod_entry(f, gd_files)

    print(f"架构纪律：{len(gd_files)} 个 .gd，{len(walk_files(ROOT / 'tools', ('.py',)))} 个工具")

    # 最常见的"假通过"是路径写错，扫到 0 个文件然后宣布一切正常。
    if not gd_files:
        print("✗ 一个 .gd 都没扫到 —— 路径出错了，这不是通过")
        return 1

    if f.empty():
        print("全部通过（R1 目录名 / R2 文件长度 / R3 域大小 / R4 引擎不认内容 /"
              " R5 依赖方向 / R6 生成物 / R7 mod 唯一入口）")
        return 0

    print(f"\n违反 {len(f.items)} 处：\n")
    for line in f.items:
        print(line)
    print("\n每条规则的出处见 docs/structure.md 与 AGENTS.md。"
          "改规则要先改文档，不要直接放宽这个脚本。")
    return 1


def run_selftest() -> int:
    """临时造违规 → 跑一遍 → 断言每条规则都出现 → 清理。

    为什么这个要在仓库里：一个永远返回 0 的检查比没有检查更糟，
    因为它给了"架构没问题"的错觉。
    """
    import shutil

    tmp = SCRIPTS / "zz_selftest"
    made: list[Path] = []

    def make(name: str, text: str) -> None:
        p = tmp / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        made.append(p)

    try:
        make("utils/x.gd", "extends Node\n")                                    # R1
        make("long.gd", "extends Node\n" + "var a := 1\n" * 420)                # R2
        make("knows_content.gd", 'extends Node\nvar who := "enemy/bone_walker"\n')  # R4
        make("dep.gd", "extends Node\nconst P := 'contract/registry.py'\n")     # R5
        make("injects.gd", "extends Node\nvar s := GDScript.new()\n")            # R7
        for i in range(13):                                                     # R3
            make(f"filler_{i:02d}.gd", "extends Node\n")

        r = subprocess.run(
            [sys.executable, str(Path(__file__).resolve())],
            cwd=ROOT, capture_output=True, text=True,
        )
        out = r.stdout + r.stderr
        expect = {
            "R1": "目录名 `utils`",
            "R2": "> 400 行上限",
            "R3": "> 12 上限",
            "R4": "enemy/bone_walker",
            "R5": "引用了 contract/",
            "R7": "运行时编译 GDScript",
        }
        missing = [k for k, needle in expect.items() if needle not in out]
        print(out.strip())
        print("-" * 56)
        if r.returncode == 0:
            print("✗ 自测失败：造了违规但 lint 返回 0")
            return 1
        if missing:
            print(f"✗ 自测失败：这些规则没触发 {missing}")
            return 1
        print("自测通过：R1/R2/R3/R4/R5/R7 都能抓到违规")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        for p in made:
            if p.exists():
                p.unlink()


if __name__ == "__main__":
    sys.exit(main())
