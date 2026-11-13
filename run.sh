#!/usr/bin/env bash
# 跑起来看看。
#
# 这不是验收入口（那是 check.sh）。它只做一件事：保证内容包不是旧的，
# 然后把窗口打开。改了 TOML 之后直接再跑一次就能看到变化。
#
# 用法：
#   ./run.sh                      正常窗口
#   ./run.sh --headless           不开窗（只打印统计）
#   GODOT=/path/to/godot ./run.sh 换引擎路径

set -uo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-tools-bin/Godot_v4.6-stable_linux.x86_64}"
if [ ! -x "$GODOT" ]; then
    echo "找不到引擎：$GODOT"
    echo "下载见 README「准备引擎」，或用 GODOT=/path/to/godot ./run.sh"
    exit 1
fi

# 内容包可能是旧的。编译一次比"打开游戏发现改的东西没出现"便宜得多。
python3 tools/contentc.py --content content --content mods \
    --out build/content.pack.json --bin build/content.pack.bin || exit 1
cp build/content.pack.json game/content.pack.json || exit 1

# 行为 mod 的源码在仓库根下（mods/scripts/*.gd），引擎要在运行时从磁盘读它。
# 显式告诉它根在哪，比让它在导出包里猜 res:// 的上一级要可靠得多。
export TESSERA_ROOT="$(pwd)"

echo
echo "启动 —— 鼠标转视角，WASD 走，空格跳，Shift 冲刺"
echo "       左键按住抓起东西，松开扔出去；R 轻轻放下；Esc 释放鼠标"
echo
exec "$GODOT" --path game "$@"
