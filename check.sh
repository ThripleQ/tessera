#!/usr/bin/env bash
# 唯一的验收入口。CI 跑的是同一个脚本，所以本地通过就等于 CI 通过。
# 不要在这里加"可选"步骤——不能失败的检查等于没有检查。

set -uo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-tools-bin/Godot_v4.6-stable_linux.x86_64}"
export GODOT_SILENCE_ROOT_WARNING=1
fail=0
# 每步耗时打在标题上方：慢的时候要能一眼看出是"引擎起不来"还是"某一步在跑物理"，
# 而不是对着一整屏绿猜。
step() {
    if [ -n "${_last:-}" ]; then
        printf '\033[2m   （上一步 %s 秒）\033[0m' "$((SECONDS - _last))"
        echo
    fi
    _last=$SECONDS
    printf '\n\033[1m== %s ==\033[0m\n' "$1"
}

# ---- 切片模式：只为"改一处、等十秒"存在 ----------------------------------
#
# `./check.sh 14` 只跑第 14 步（外加 1/3/4 这三个便宜且是前提的步骤）。
# 全套 17 步约 110 秒，其中 12 步各自冷启动一次引擎；改一行角色代码要等两分钟，
# 于是"顺手也跑一遍"变成"懒得跑"，或者反过来"跑一次就以为验完了"。
#
# 它守不住的东西必须说在明处：切片只证明**那一步**是对的，不证明别的步骤没被
# 碰坏。所以它永不打印"验收通过"，CI 里被硬拒绝（CI 跑的永远是全套），
# 提交前也必须跑一次全套 —— 这条写进 AGENTS。
only="${*:-}"
slice=0
[ -n "$only" ] && slice=1
if [ "$slice" = 1 ] && [ -n "${CI:-}" ]; then
    printf '\033[31m拒绝\033[0m：CI 里不许切片，验收必须跑全套\n'
    exit 1
fi
want() {   # $1=步号；返回 0 = 该跑
    [ "$slice" = 0 ] && return 0
    case " $only " in *" $1 "*) return 0 ;; esac
    # 编译内容 / 架构纪律 / 同步产物：便宜，且后面每一步都依赖它们
    case " 1 3 4 " in *" $1 "*) return 0 ;; esac
    return 1
}
skip() { printf '\033[2m   （切片模式，跳过 %s）\033[0m\n' "$1"; }

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

step "1/17 编译基础内容（解析 → 继承 → 校验 → 产物）"
if want 1; then
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

else
    skip 1
fi
step "2/17 编译每个 mod（各自独立产物）"
if want 2; then
# mod 是可独立发布的单元，所以它有自己的一步编译。这里不合并成一个包：
# 合并是运行时的事（按授权顺序叠加），编译期合并会让"谁覆盖了谁"变得不可见。
for d in mods/*/; do
    [ -d "$d" ] || continue
    python3 tools/contentc.py --mod "$d" --base content || fail=1
done

else
    skip 2
fi
step "3/17 架构纪律（目录名 / 文件长度 / 域大小 / 引擎不认内容 / 依赖方向 / mod 唯一入口）"
if want 3; then
# 先验证检查器本身没退化成"永远通过"，再跑真正的检查。
if python3 tools/lint_arch.py --selftest > build/lint_selftest.log 2>&1; then
    echo "检查器自测：通过（R1-R7 每条都能抓到违规）"
else
    tail -40 build/lint_selftest.log
    fail=1
fi
python3 tools/lint_arch.py || fail=1

else
    skip 3
fi
step "4/17 同步内容包到 Godot 工程"
if want 4; then
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

else
    skip 4
fi
step "5/17 Godot 无头自检（内容 / 契约 / 网格 / 钩子 / mod）"
if want 5; then
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

else
    skip 5
fi
step "6/17 系统层（怪会动 → 会死 → 会掉）"
if want 6; then
# `move` / `ai` / `health` / `loot` 在此之前是死数据：契约声明了、内容填了、
# 引擎一行都没读。菜单里的"骨行者"放下去是个雕像。
# 四条断言各守各的：是刚体（能抓能扔）、会动（系统写了速度）、
# 会死（血扣光要离开世界）、会掉（死了要有东西）。
#
# 会动那条验的是**速度**不是位移 —— 无头下几百 fps，几十帧的位移小到测不准，
# 而"系统有没有把意图写进物理"这件事本身是确定的。
# 掉落那条把概率推到 1.0：概率只是一次 randf 比较，没有可测的逻辑，
# 而"靠运气的断言"会天天翻脸。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/actors.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(ACTOR)'
no_engine_errors "$out" "系统层" || fail=1
if ! echo "$out" | grep -q 'ACTOR RESULT OK'; then
    echo "系统层未通过"
    fail=1
fi

else
    skip 6
fi
step "7/17 存档往返（推箱子 + 放固定物 + 背包 → 存 → 再推 → 读档）"
if want 7; then
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

else
    skip 7
fi
step "8/17 生成菜单与背包（放 → 收 → 堆叠上限 → 背包放回 → 拆）"
if want 8; then
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

else
    skip 8
fi
step "9/17 剔除（逐件判过）与性能成本（结构指标，不设毫秒断言）"
if want 9; then
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

# 性能这一段**没有毫秒断言**，只打印。
#
# 为什么破例：这台机器没有 GPU，无头主循环自己就有 ~6.8 ms 地板
# （空场景也是 6.90 ms），帧时对世界的工作量不敏感 —— 在这里设阈值
# 等于设一个不看内容的红灯，而红灯一旦习惯性被忽略，就等于没有红灯。
#
# 所以这一段只负责"让人看见"：结构指标（材质份数、视锥次数、节点数）、
# 同机成本对拍（新旧写法）、以及常态负载。真正会失败的是第 13 步 ——
# 它守的是结构，不是毫秒。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/perf.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(PERF)'
no_engine_errors "$out" "剔除与性能成本" || fail=1

else
    skip 9
fi
step "10/17 L4 扩展（mod 自带组件 / 系统 / 规则状态 / 权限边界）"
if want 10; then
# 这一项必须真的跑一个 mod 系统：自检只到 Plan 层，调度器一个节点都不建。
# 四条断言各守各的 —— 声明进 schema、脚本编译进调度器、固定节拍写了状态、
# 没声明的读写与错类型值被挡住。最后一条尤其重要：开放不等于把节点交出去。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/extensions.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(EXT)'
no_engine_errors "$out" "L4 扩展" || fail=1
if ! echo "$out" | grep -q 'EXT RESULT OK'; then
    echo "L4 扩展未通过"
    fail=1
fi

else
    skip 10
fi
step "11/17 外观开放（文件夹里的模型真的盖掉引擎内置几何）"
if want 11; then
# 这一项必须真的加载一份外部 glTF：自检只到 Plan 层，看不见"换外貌"这件事。
# 断言各守各的 —— 覆盖被发现、三角形数与内置不同、世界里刚体的视觉网格
# **就是**资源层给出的那个对象（漏改一个调用点就会红）、回退与优先级有边界。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/assets.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(ASSET)'
no_engine_errors "$out" "外观开放" || fail=1
if ! echo "$out" | grep -q 'ASSET RESULT OK'; then
    echo "外观开放未通过"
    fail=1
fi

else
    skip 11
fi
step "12/17 真实玩法扩展（agent 新增 mod 能改变物理世界）"
if want 12; then
# 前面只证明 L4 通道“能装载、能写自己的状态”；这一步证明它能做出真实玩法：
# 一个只走公开契约、脚本与 api 的 mod，按固定节拍推开附近任意刚体。
# 探针不认识内容 id，只按组件语义找机关与目标，因此以后 agent 再加刚体也能参与。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/physical_rules.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(RULE)'
no_engine_errors "$out" "真实玩法扩展" || fail=1
if ! echo "$out" | grep -q 'RULE RESULT OK'; then
    echo "真实玩法扩展未通过"
    fail=1
fi

else
    skip 12
fi
step "13/17 性能结构（材质共用 / 染色隔离 / 视锥每帧一次 / 剔除变快 / 无孤儿）"
if want 13; then
# 这一步守的是**结构**，不是毫秒。这台机器没有 GPU，无头主循环自己就有
# ~6.8 ms 的地板（空场景实测），墙上帧时测不出 1 ms 级差别 ——
# 项目之前把那个数字当基线追了好几轮，实际上一直在测环境。
# 能守的是和机器无关的东西：材质是不是 O(配色)、视锥建几次、剔除快不快、
# 染色会不会串到别的实例。它们退步时功能全绿，只有真机上会变卡。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/budget.gd \
    -- --fresh --trust=all 2>&1)
echo "$out" | grep -E '^(BUDGET)'
no_engine_errors "$out" "性能结构" || fail=1
if ! echo "$out" | grep -q 'BUDGET RESULT OK'; then
    echo "性能结构未通过"
    fail=1
fi

else
    skip 13
fi
step "14/17 角色资产（带动画的人 / 脚贴地 / 卡通材质 / 能回退 / 骨骼真的在动 / 目录里每个角色）"
if want 14; then
# 这一轮之前，玩家是一坨"会平移的几何"：功能全对，动画全无。
# 所以这一步守的不是模型好不好看，而是**人是不是真的在动** ——
# 直接采样骨骼姿势跨帧比较，而不是看 AnimationPlayer 当前播的片段名。
# 负向验证过：掐掉 `_ap.play()`，状态名仍然全对，只有"动"这一条会红。
#
# 同时把 `assets/characters/` 里的**每一个**角色都当成玩家试一遍。
# 只验当前那个，等于只验了 knight：新加的角色即便人陷进地里、手里举着
# 四把剑、走起来在冰上滑，这一步照样是绿的 —— 而"加角色不用改代码"
# 是这套通道的全部卖点。
out=$(timeout 180 "$GODOT" --headless --path game --script res://probes/character.gd \
    -- --fresh 2>&1)
echo "$out" | grep -E '^CHAR'
no_engine_errors "$out" "角色资产" || fail=1
if ! echo "$out" | grep -q 'CHAR RESULT OK'; then
    echo "角色资产未通过"
    fail=1
fi

else
    skip 14
fi
step "15/17 步态匹配（档位由资产声明 / 速度带无缝 / 支撑脚不打滑 / 有牙）"
if want 15; then
# 这一轮之前，人是"腿在迈、身体在冰上滑"：4.6 m/s 的速度配着画到 0.55 m/s 的动画。
# 这一步守的是**位移对账**：支撑脚相对身体的后撤速率必须等于身体速度，
# 差值就是脚在世界里真实滑动的速度。
#
# 量它用的是真实播放器驱动的骨架（seek + Skeleton3D 实际姿态），
# 和被测的曲线求值是两套独立实现 —— 拿同一个函数验自己等于没验。
out=$(timeout 300 "$GODOT" --headless --path game --script res://probes/locomotion.gd \
    -- --fresh 2>&1)
echo "$out" | grep -E '^(LOCO)'
no_engine_errors "$out" "步态匹配" || fail=1
if ! echo "$out" | grep -q 'LOCO RESULT OK'; then
    echo "步态匹配未通过"
    fail=1
fi

else
    skip 15
fi
step "16/17 世界里的人（新丢一个 glb 就多一个人 / 同一份资产能要两次 / 真的在走）"
if want 16; then
# 第 14 步证明的是"拿得起来"：把每个角色单独建成玩家的样子体检一遍。
# 这一步证明的是"放进世界里还能走"—— 那是另一条链：
# character_assets → character_rig → gait → 物理 → 动画。
#
# 它唯一会静默坏掉的症状，正是这一步要消灭的那个：**人站着平移**。
# 功能全对、状态名全对、日志全绿，画面上是一个人贴着地面飘。
# 所以这里不看名字、不看日志，只量两件事：位置挪了多远、骨头动没动。
#
# "同一份资产能要两次"是顺手但必守的一条：把加载结果缓存起来复用，
# 会让第二个人把第一个人从世界里拽走（节点只能有一个父节点），
# 而症状是"加了个 NPC 之后玩家不见了"，没有任何报错。
out=$(timeout 240 "$GODOT" --headless --path game --script res://probes/cast.gd \
    -- --fresh 2>&1)
echo "$out" | grep -E '^CAST'
no_engine_errors "$out" "阵容" || fail=1
if ! echo "$out" | grep -q 'CAST RESULT OK'; then
    echo "阵容未通过"
    fail=1
fi

step "17/17 手里的枪（数值来自内容 / 打中会疼 / 打死会记 / 会打空 / 后坐会回 / 视角分离）"
if want 17; then
# 第 6 步验的是**撞击**伤害：箱子以 8 m/s 砸中会疼。子弹不是物理体，
# 它是一条射线 —— 两条伤害路径长得像，错的却不是同一处（那边靠 impacts 队列，
# 这边靠直接调用）。只验一条，另一条可以在全绿的情况下彻底不通。
#
# 六条各错各的：数值来自内容（不是引擎里的巧合常量）、打中会疼、打死会记、
# 会打空、后坐会回（只有抬没有回 = 准星永久跑偏）、视角分离（第三人称下
# 不该飘着一把没有人的枪）。
out=$(timeout 240 "$GODOT" --headless --path game --script res://probes/firefight.gd \
    -- --fresh 2>&1)
echo "$out" | grep -E '^GUN'
no_engine_errors "$out" "枪" || fail=1
if ! echo "$out" | grep -q 'GUN RESULT OK'; then
    echo "枪未通过"
    fail=1
fi
else
    skip 17
fi

echo
if [ "$fail" -ne 0 ]; then
    printf '\033[31m验收失败\033[0m\n'
    exit 1
fi
if [ "$slice" = 1 ]; then
    printf '\033[33m切片通过\033[0m —— 只跑了 %s 步，这不代表可以提交。提交前跑一次 ./check.sh\n' "$only"
    exit 0
fi
printf '\033[32m验收通过\033[0m —— 内容可编译、mod 可独立编译、架构无违规、契约无冲突、引擎能加载、怪会动会死会掉、存档能往返、菜单能生成、剔除判得对、L4 扩展能装载能跑且有边界、外观开放能换几何、真实玩法能只靠公开扩展通道、性能结构不退化、角色带骨骼动画且脚贴地、目录里每个角色都能用、走跑时支撑脚不打滑、世界里的别人真的在走、手里的枪能打死东西、引擎无报错\n'

else
    skip 16
fi