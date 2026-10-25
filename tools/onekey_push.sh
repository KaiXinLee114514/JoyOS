#!/usr/bin/env bash
# ============================================================================
#  onekey_push.sh — 一键推送到 GitHub:自动重试 + 可选 GH_TOKEN(不落盘)
#
#  为什么:
#    国内访问 GitHub 时通时不通,手动 git push 一次超时就白等。
#    这个脚本失败后隔几秒重试,网络抖一下也能推上去;token 只从环境变量
#    读,不写进 .git/config / ~/.git-credentials。
#
#  用法:
#    tools/onekey_push.sh                        # 推 origin/main(靠已配置凭据或 SSH)
#    GH_TOKEN=ghp_xxx tools/onekey_push.sh       # PAT 放环境变量(推荐)
#    tools/onekey_push.sh --branch dev --retry 8 --sleep 15
#    tools/onekey_push.sh --dry-run              # 只打印要推什么,不动远程
#
#  小提示:想让它记住 token,可以自己配 credential.helper(见 README 的说明),
#  或者每次从密码管理器里拷进环境变量 —— 脚本本身不留任何东西。
# ============================================================================
set -uo pipefail

BRANCH=main
RETRIES=6
SLEEP=8
DRY_RUN=0

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --branch|-b) BRANCH="${2:-}"; shift 2 ;;
        --retry|-r)  RETRIES="${2:-}"; shift 2 ;;
        --sleep|-s)  SLEEP="${2:-}"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "未知参数: $1(试试 --help)"; exit 1 ;;
    esac
done

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "✗ 当前目录不是 git 仓库"
    exit 1
fi

REMOTE_URL="$(git config --get remote.origin.url || true)"
if [ -z "$REMOTE_URL" ]; then
    echo "✗ 这个仓库没有 remote.origin"
    exit 1
fi

if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    AHEAD="$(git rev-list --count "origin/$BRANCH..HEAD")"
else
    AHEAD="?"
fi
LOCAL_HEAD="$(git log --oneline -1 2>/dev/null || echo '(还没有提交)')"

echo "仓库:   $REMOTE_URL"
echo "分支:   $BRANCH"
echo "待推:   $AHEAD 个提交"
echo "本地头: $LOCAL_HEAD"

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "--dry-run:不推送。要推的提交:"
    if [ "$AHEAD" != "?" ] && [ "$AHEAD" != "0" ]; then
        git log --oneline "origin/$BRANCH..HEAD"
    else
        echo "  (没有需要推的)"
    fi
    exit 0
fi

# ---- 组装 push 命令(GH_TOKEN 有值就走 Basic 认证,否则交给 git 自己的凭据)----
GIT_PUSH=(git push origin "$BRANCH")
if [ -n "${GH_TOKEN:-}" ]; then
    _auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
    GIT_PUSH=(git -c "http.extraHeader=AUTHORIZATION: basic $_auth" push origin "$BRANCH")
    echo "认证:   GH_TOKEN(环境变量,不落盘)"
else
    echo "认证:   git 自带凭据/SSH(没配的话会失败 —— 设 GH_TOKEN 或配置 credential.helper)"
fi
echo

# ---- 重试循环 ----
attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
    echo "--- 第 $attempt/$RETRIES 次尝试 ..."
    if "${GIT_PUSH[@]}"; then
        echo
        echo "✅ 推送成功: $(git log --oneline -1)"
        exit 0
    fi
    if [ "$attempt" -lt "$RETRIES" ]; then
        echo "   失败,${SLEEP}s 后重试(不想等就 Ctrl-C)"
        sleep "$SLEEP"
    fi
    attempt=$((attempt + 1))
done

echo
echo "✗ 连试 $RETRIES 次都失败。排查建议:"
echo "    curl -I --max-time 10 https://github.com    # 先确认网络"
echo "    ping github.com"
echo "    echo \$HTTPS_PROXY      # 有代理的话带上"
exit 1
