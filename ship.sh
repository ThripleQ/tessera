#!/usr/bin/env bash
# 一条命令把改动交给 CI 验收：便宜的检查在本地跑，贵的（13 次引擎启动）在 CI 跑。
#
#   ./ship.sh "commit message"
#   ./ship.sh                      # 改动已经提交过，只等 CI
#
# 为什么这么分：
#   本机约 150 秒 / CI 30–45 秒。差的不是网络，是引擎冷启动 13 次 × 8–10 秒，
#   加上这台机器没有 GPU 只能软件跑。而 CI 的机器比本机快得多。
#
# 本地仍要跑的那两样是"最常犯、最便宜"的错：内容编译不过、架构纪律违规
# （单文件超 400 行、目录名、依赖方向）。它们只要 5 秒，且能在我还没推送时
# 就把我拦住 —— 推到远端才发现 400 行，等于浪费一次 CI。
#
# 报错时把失败那段日志直接打出来，不用再去网页上翻。

set -uo pipefail
cd "$(dirname "$0")"

msg="${1:-}"
branch="$(git rev-parse --abbrev-ref HEAD)"

say() { printf '\033[1m== %s ==\033[0m\n' "$1"; }

# ---- 1. 便宜的本地检查：内容编译 + 架构纪律 -------------------------------
say "本地：内容编译与架构纪律（约 5 秒）"
mkdir -p build
if ! python3 tools/contentc.py --content content \
        --out build/content.pack.json --bin build/content.pack.bin --report; then
    printf '\033[31m内容编译失败\033[0m —— 没有推送\n'
    exit 1
fi
if ! python3 tools/lint_arch.py; then
    printf '\033[31m架构纪律失败\033[0m —— 没有推送（这条在本地拦下，就不浪费一次 CI）\n'
    exit 1
fi

# ---- 2. 提交（有改动时）---------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
    if [ -z "$msg" ]; then
        printf '\033[31m有未提交的改动，但没给提交信息\033[0m\n'
        printf '用法：./ship.sh "改了什么"\n'
        exit 1
    fi
    say "提交"
    git add -A
    git commit -q -m "$msg" || { printf '\033[31m提交失败\033[0m\n'; exit 1; }
    git log --oneline -1
elif [ -z "$msg" ]; then
    echo "没有要提交的改动，直接等 CI 验收当前 HEAD"
fi

sha="$(git rev-parse HEAD)"
say "推送 $branch @ ${sha:0:7}"
# 不接管道：pipefail 本来就能兜住退出码，但 `| tail` 会把失败原因截成三行。
# 推上去必须看得见结果，包括失败时 git 说的那一整段。
if ! git push origin "$branch"; then
    printf '\033[31m推送失败\033[0m\n'
    exit 1
fi

# ---- 3. 等这一次推送的 CI -------------------------------------------------
# 推送后 run 不会立刻出现，所以要轮询到"属于这个 sha 的那个 run"。
say "等 CI（全套 16 步，约 30 秒）"
run=""
for _ in $(seq 1 20); do
    run="$(gh run list --limit 8 --json databaseId,headSha,workflowName \
        --jq "[.[] | select(.headSha == \"$sha\")][0].databaseId" 2>/dev/null)"
    [ -n "$run" ] && [ "$run" != "null" ] && break
    sleep 2
done
if [ -z "$run" ] || [ "$run" = "null" ]; then
    printf '\033[31m找不到这个提交的 CI\033[0m：gh run list --limit 3 自己看一眼\n'
    exit 1
fi
echo "run $run"

gh run watch "$run" --interval 5 --exit-status > /tmp/tessera_ci.log 2>&1
ok=$?
if [ "$ok" -ne 0 ]; then
    printf '\033[31mCI 失败\033[0m —— 失败那一段在下面，修完再 ./ship.sh\n\n'
    gh run view "$run" --log-failed 2>/dev/null | tail -40
    exit 1
fi

# ---- 4. 收工 --------------------------------------------------------------
printf '\033[32mCI 绿\033[0m —— 十六步全套通过（%s 秒）\n' "$SECONDS"
echo "run: https://github.com/ThripleQ/tessera/actions/runs/$run"
