#!/usr/bin/env bash
# 唯一的验收入口。CI 跑的是同一个脚本，所以本地通过就等于 CI 通过。
# 不要在这里加"可选"步骤——不能失败的检查等于没有检查。

set -uo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-tools-bin/Godot_v4.6-stable_linux.x86_64}"
export GODOT_SILENCE_ROOT_WARNING=1
fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "1/4 编译内容（解析 → 继承 → 校验 → 产物）"
python3 tools/contentc.py --content content --content mods \
    --out build/content.pack.json --bin build/content.pack.bin --report || fail=1

step "2/4 架构纪律（目录名 / 文件长度 / 域大小 / 引擎不认内容 / 依赖方向）"
# 先验证检查器本身没退化成"永远通过"，再跑真正的检查。
if python3 tools/lint_arch.py --selftest > build/lint_selftest.log 2>&1; then
    echo "检查器自测：通过（R1-R5 每条都能抓到违规）"
else
    tail -40 build/lint_selftest.log
    fail=1
fi
python3 tools/lint_arch.py || fail=1

step "3/4 同步内容包到 Godot 工程"
cp build/content.pack.json game/content.pack.json || fail=1

step "4/4 Godot 无头自检"
if [ ! -x "$GODOT" ]; then
    echo "找不到引擎：$GODOT"
    echo "下载见 README「准备引擎」，或用 GODOT=/path/to/godot ./check.sh"
    fail=1
else
    # --quit-after 是死循环保险；但它退出码恒为 0，所以必须靠输出里的标记判定，
    # 否则脚本崩了也会"通过"。
    out=$("$GODOT" --headless --path game --quit-after 600 -- --selftest 2>&1)
    echo "$out" | grep -v '^Godot Engine'
    if ! echo "$out" | grep -q '自检通过'; then
        echo "自检未打印通过标记"
        fail=1
    fi
fi

echo
if [ "$fail" -ne 0 ]; then
    printf '\033[31m验收失败\033[0m\n'
    exit 1
fi
printf '\033[32m验收通过\033[0m —— 内容可编译、架构无违规、契约无冲突、引擎能加载\n'
