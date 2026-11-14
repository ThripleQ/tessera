#!/usr/bin/env bash
# 唯一的验收入口。CI 跑的是同一个脚本，所以本地通过就等于 CI 通过。
# 不要在这里加"可选"步骤——不能失败的检查等于没有检查。

set -uo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-tools-bin/Godot_v4.6-stable_linux.x86_64}"
export GODOT_SILENCE_ROOT_WARNING=1
fail=0
step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

# 引擎自己的报错一律算失败。
#
# 这几步原来只 grep 业务标记（`RESULT OK` / `自检通过`），于是"功能对、但引擎在骂人"
# 的那一类问题在验收里完全看不见：0 个失败断言 + 1 屏 ERROR。
# 真实案例：`bodies.find(墙)` 拿 StaticBody3D 去 `Array[RigidBody3D]` 里找，
# 引擎报错再返回 -1 —— 恰好落到正确分支，所以断言全绿，只有玩家每右键一次墙，
# 日志就脏一行。这类"刚好对"的实现是最难被发现的，因为它永远不失败。
#
# 什么时候它会误伤：当你依赖某个引擎的 ERROR 来正常工作。那就是实现该修了。
no_engine_errors() {   # $1=输出  $2=步骤名
    if echo "$1" | grep -qE '^(ERROR|SCRIPT ERROR)'; then
        echo "$1" | grep -E '^(ERROR|SCRIPT ERROR)' | head -10
        echo "$2 出现引擎报错（见上）—— 功能可能仍然是对的，但这不是可以留着的东西"
        return 1
    fi
    return 0
}

# build/ 必须在第一步之前就存在。原来它是由"编译内容"顺手创建的，
# 而编译器自测排在编译之前 —— 于是本地（build/ 早就在）通过，CI（干净 clone）红，
# 而且错误只是 `No such file or directory`，看起来像环境问题。
mkdir -p build

step "1/8 编译基础内容（解析 → 继承 → 校验 → 产物）"
# 先验证编译器本身没退化成"永远接受"，再编译真内容。
# 一个从来没拒绝过东西的校验器，和不存在没有区别 —— 而且它还是绿的。
if out=$(python3 tools/contentc.py --selftest 2>&1); then
    echo "$out"
else
    echo "$out"
    fail=1
fi
python3 tools/contentc.py --content content \
    --out build/content.pack.json --bin build/content.pack.bin --report || fail=1

step "2/8 编译每个 mod（各自独立产物）"
# mod 是可独立发布的单元，所以它有自己的一步编译。这里不合并成一个包：
# 合并是运行时的事（按授权顺序叠加），编译期合并会让"谁覆盖了谁"变得不可见。
for d in mods/*/; do
    [ -d "$d" ] || continue
    python3 tools/contentc.py --mod "$d" --base content || fail=1
done

step "3/8 架构纪律（目录名 / 文件长度 / 域大小 / 引擎不认内容 / 依赖方向 / mod 唯一入口）"
# 先验证检查器本身没退化成"永远通过"，再跑真正的检查。
if python3 tools/lint_arch.py --selftest > build/lint_selftest.log 2>&1; then
    echo "检查器自测：通过（R1-R7 每条都能抓到违规）"
else
    tail -40 build/lint_selftest.log
    fail=1
fi
python3 tools/lint_arch.py || fail=1

step "4/8 同步内容包到 Godot 工程"
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

step "5/8 Godot 无头自检（内容 / 契约 / 网格 / 钩子 / mod）"
# --trust=all：验收必须真的跑到脚本通道。不授权的话带脚本的 mod 会被
# 授权闸门挡住，自检发现"一个脚本都没加载"就判失败 —— 那种绿毫无意义。
#
# --quit-after 是死循环保险；但它退出码恒为 0，所以必须靠输出里的标记判定，
# 否则脚本崩了也会"通过"。
out=$(timeout 180 "$GODOT" --headless --path game --quit-after 600 -- --selftest --trust=all 2>&1)
echo "$out" | grep -v '^Godot Engine'
no_engine_errors "$out" "自检" || fail=1
if ! echo "$out" | grep -q '自检通过'; then
    echo "自检未打印通过标记"
    fail=1
fi

step "6/8 存档往返（推箱子 + 放固定物 + 背包 → 存 → 再推 → 读档）"
# 这一项必须真跑。自检只走到 Plan 层，不实例化玩家、不跑物理，
# 所以坐标编码、刚体重建、handle 作废全在它的覆盖之外 ——
# 而这类代码的错法是"看起来存了，读回来差一点"，只有对比数字能发现。
# TESSERA_SAVE_SLOT 保证它绝不动玩家真正的存档。
export TESSERA_SAVE_SLOT=probe.json
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/save_roundtrip.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(SAVE|RESULT)'
no_engine_errors "$out" "存档往返" || fail=1
if ! echo "$out" | grep -q 'RESULT 位置 OK / 数量 OK / 玩家 OK / 固定物 OK / 背包 OK'; then
    echo "存档往返未通过"
    fail=1
fi

step "7/8 生成菜单与背包（放 → 收 → 堆叠上限 → 背包放回 → 拆）"
# 菜单是纯运行时 UI，自检一个节点都不建。它坏起来很安静：
# "能打开但点了没反应"、"关掉之后操作还卡着"，两种都不报错。
# 收 / 放回 / 堆叠也在这里验：预算归还、库存扣减、堆叠上限、
# 价值合计、房间障碍收不走 —— 最后一条是"内容 vs 玩家"那条分界的守卫。
# 无头也能验逻辑，只是拿不到截图 —— 截图只在本机有显示的时候产出。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/spawn_menu.gd \
    -- --fresh --trust=all 2>&1)
# SCRAPE / STACK 行也放出来：拆的四条路和堆叠规则各错各的，
# 失败时唯一有用的信息就在这几行里，
# 而 RESULT 只告诉你"有一项 FAIL"——把它藏起来等于让下一个人从零开始复现。
echo "$out" | grep -E '^(MENU|SCRAPE|STACK)'
no_engine_errors "$out" "生成菜单" || fail=1
if ! echo "$out" | grep -q 'MENU RESULT OK'; then
    echo "生成菜单未通过"
    fail=1
fi

step "8/8 剔除（逐件判过）与帧时基线（不设断言）"
# 剔除坏起来不报错：该剔的没剔只是帧时慢慢涨，剔多了玩家只看到世界在闪。
# 所以它必须有断言 —— 而且要测两条**不同**的路：
# 距离（远处那件）和视锥（侧面那件）。只测远处的话，视锥写坏也发现不了，
# 因为距离先把它拦了。对拍那条拿 Godot 自己的 is_position_in_frustum 当标准答案，
# 守着 culling.gd 里那两个被写反过两次的符号。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/culling.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(CULL)'
no_engine_errors "$out" "剔除" || fail=1
if ! echo "$out" | grep -q 'CULL RESULT OK'; then
    echo "剔除未通过"
    fail=1
fi

# 帧时这一段**没有失败条件**，它是唯一一个故意不判对错的检查。
#
# 为什么破例：帧时的绝对值依赖机器。开发机没有 GPU、只能软件光栅，
# 在这里设阈值 = 在 CI 上设一个天天翻脸的红灯，而红灯一旦习惯性被忽略，
# 就等于没有红灯。所以它只打印，供人和**同一台机器的上一次**比。
#
# 它拦的是"功能全绿但游戏卡了"那一类问题：上面的断言都只看结果对不对，
# 没有一个看每帧花了多少。而这类退化不会自己报警 —— 等玩家说"卡"的时候，
# 已经不知道是哪一次提交带进来的了。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/perf.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(PERF)'
no_engine_errors "$out" "帧时基线" || fail=1

echo
if [ "$fail" -ne 0 ]; then
    printf '\033[31m验收失败\033[0m\n'
    exit 1
fi
printf '\033[32m验收通过\033[0m —— 内容可编译、mod 可独立编译、架构无违规、契约无冲突、引擎能加载、存档能往返、菜单能生成、剔除判得对、引擎无报错、帧时有基线\n'
