#!/usr/bin/env bash
# 唯一的验收入口。CI 跑的是同一个脚本，所以本地通过就等于 CI 通过。
# 不要在这里加"可选"步骤——不能失败的检查等于没有检查。

set -uo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-tools-bin/Godot_v4.6-stable_linux.x86_64}"
export GODOT_SILENCE_ROOT_WARNING=1
fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

step "1/7 编译基础内容（解析 → 继承 → 校验 → 产物）"
# 先验证编译器本身没退化成"永远接受"，再编译真内容。
# 一个从来没拒绝过东西的校验器，和不存在没有区别 —— 而且它还是绿的。
if python3 tools/contentc.py --selftest > build/contentc_selftest.log 2>&1; then
    echo "编译器自测：通过（5 条规则都能抓到违规）"
else
    cat build/contentc_selftest.log
    fail=1
fi
python3 tools/contentc.py --content content \
    --out build/content.pack.json --bin build/content.pack.bin --report || fail=1

step "2/7 编译每个 mod（各自独立产物）"
# mod 是可独立发布的单元，所以它有自己的一步编译。这里不合并成一个包：
# 合并是运行时的事（按授权顺序叠加），编译期合并会让"谁覆盖了谁"变得不可见。
for d in mods/*/; do
    [ -d "$d" ] || continue
    python3 tools/contentc.py --mod "$d" --base content || fail=1
done

step "3/7 架构纪律（目录名 / 文件长度 / 域大小 / 引擎不认内容 / 依赖方向 / mod 唯一入口）"
# 先验证检查器本身没退化成"永远通过"，再跑真正的检查。
if python3 tools/lint_arch.py --selftest > build/lint_selftest.log 2>&1; then
    echo "检查器自测：通过（R1-R7 每条都能抓到违规）"
else
    tail -40 build/lint_selftest.log
    fail=1
fi
python3 tools/lint_arch.py || fail=1

step "4/7 同步内容包到 Godot 工程"
cp build/content.pack.json game/content.pack.json || fail=1

# 行为 mod 的源码是运行时从磁盘编译的，根目录得显式给 —— 否则 CI 里找不到文件，
# 而本地能跑通，是最难查的一种不一致。
export TESSERA_ROOT="$(pwd)"

if [ ! -x "$GODOT" ]; then
    echo
    echo "找不到引擎：$GODOT"
    echo "下载见 README「准备引擎」，或用 GODOT=/path/to/godot ./check.sh"
    printf '\n\033[31m验收失败\033[0m\n'
    exit 1
fi

step "5/7 Godot 无头自检（内容 / 契约 / 网格 / 钩子 / mod）"
# --trust=all：验收必须真的跑到脚本通道。不授权的话带脚本的 mod 会被
# 授权闸门挡住，自检发现"一个脚本都没加载"就判失败 —— 那种绿毫无意义。
#
# --quit-after 是死循环保险；但它退出码恒为 0，所以必须靠输出里的标记判定，
# 否则脚本崩了也会"通过"。
out=$(timeout 180 "$GODOT" --headless --path game --quit-after 600 -- --selftest --trust=all 2>&1)
echo "$out" | grep -v '^Godot Engine'
if ! echo "$out" | grep -q '自检通过'; then
    echo "自检未打印通过标记"
    fail=1
fi

step "6/7 存档往返（推箱子 + 放固定物 → 存 → 再推 → 读档）"
# 这一项必须真跑。自检只走到 Plan 层，不实例化玩家、不跑物理，
# 所以坐标编码、刚体重建、handle 作废全在它的覆盖之外 ——
# 而这类代码的错法是"看起来存了，读回来差一点"，只有对比数字能发现。
# TESSERA_SAVE_SLOT 保证它绝不动玩家真正的存档。
export TESSERA_SAVE_SLOT=probe.json
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/save_roundtrip.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(SAVE|RESULT)'
if ! echo "$out" | grep -q 'RESULT 位置 OK / 数量 OK / 玩家 OK / 固定物 OK'; then
    echo "存档往返未通过"
    fail=1
fi

step "7/7 生成菜单（开菜单 → 放刚体 → 放固定物 → 关菜单）"
# 菜单是纯运行时 UI，自检一个节点都不建。它坏起来很安静：
# "能打开但点了没反应"、"关掉之后操作还卡着"，两种都不报错。
# 无头也能验逻辑，只是拿不到截图 —— 截图只在本机有显示的时候产出。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/spawn_menu.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^MENU'
if ! echo "$out" | grep -q 'MENU RESULT OK'; then
    echo "生成菜单未通过"
    fail=1
fi

echo
if [ "$fail" -ne 0 ]; then
    printf '\033[31m验收失败\033[0m\n'
    exit 1
fi
printf '\033[32m验收通过\033[0m —— 内容可编译、mod 可独立编译、架构无违规、契约无冲突、引擎能加载、存档能往返、菜单能生成\n'
