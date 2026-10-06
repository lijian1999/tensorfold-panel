#!/bin/sh
# 查看 / 安装 / 移除 Spark 上部署仓库里的副屏外挂补丁。
#
# 用法（在 MacBook Pro 上执行）：
#   scripts/hook.sh status     查看：补丁在不在部署仓库里、/health 里有没有 tfpanel（只读）
#   scripts/hook.sh install    把 hook/0900-tfpanel-hook.patch 拷进部署仓库的 patches/
#   scripts/hook.sh remove     从部署仓库的 patches/ 删掉它
#
# 环境变量：
#   TFPANEL_HOST    主机名，默认 spark（SSH 里配好的名字）
#   TFPANEL_DEPLOY  Spark 上部署仓库的目录，默认 Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
#                   （相对路径算在主目录下；给绝对路径时按绝对路径算，测试用）
#
# 三个动作都只动补丁文件，不碰正在运行的模型；补丁要重启模型才生效，重启由人来做。

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST=${TFPANEL_HOST:-spark}
DEPLOY=${TFPANEL_DEPLOY:-Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold}
PATCH=0900-tfpanel-hook.patch
LOCAL="$ROOT/hook/$PATCH"
RESTART="需要重启模型才能生效：在 Spark 上进入部署仓库执行 ./start.sh restart（重启期间模型不可用）"

usage() {
  cat <<'EOF'
用法：scripts/hook.sh status     查看：补丁在不在部署仓库里、/health 里有没有 tfpanel
      scripts/hook.sh install    把 hook/0900-tfpanel-hook.patch 拷进部署仓库的 patches/
      scripts/hook.sh remove     从部署仓库的 patches/ 删掉它

环境变量：TFPANEL_HOST（默认 spark）、TFPANEL_DEPLOY（Spark 上部署仓库的目录）
EOF
}

# 在 Spark 上问出部署仓库的目录（相对路径算在主目录下）
remote_deploy_dir() {
  ssh "$HOST" </dev/null "sh -s -- '$DEPLOY'" <<'REMOTE'
d=$1
case "$d" in
/*) : ;;
*) d="$HOME/$d" ;;
esac
printf '%s\n' "$d"
REMOTE
}

# 在 Spark 上取两样东西，各占一行：补丁文件的校验和（不在就写 MISSING）、/health 的返回
# $1 = 部署仓库目录，$2 = 补丁文件名
remote_probe() {
  ssh "$HOST" "sh -s -- '$1' '$2'" <<'REMOTE'
p="$1/patches/$2"
if [ -f "$p" ]; then
  cksum "$p" 2>/dev/null | cut -d ' ' -f1,2
else
  echo MISSING
fi
curl -s -m 3 http://127.0.0.1:8888/health || echo NOHEALTH
REMOTE
}

case ${1:-} in
status)
  dir=$(remote_deploy_dir) || dir=""
  if [ -z "$dir" ]; then
    echo "连不上 $HOST，问不到部署仓库的位置"
    exit 1
  fi
  probe=$(remote_probe "$dir" "$PATCH") || probe=""
  if [ -z "$probe" ]; then
    echo "读不到部署仓库和 /health：检查 $HOST 能不能连上、8888 有没有服务"
    exit 1
  fi

  sum=$(printf '%s\n' "$probe" | sed -n '1p')
  health=$(printf '%s\n' "$probe" | sed -n '2p')

  # 第一行：补丁文件在不在部署仓库里，在的话跟本地的那份比一下
  if [ "$sum" = "MISSING" ]; then
    echo "补丁文件：未放入"
    in_repo=0
  else
    if [ -f "$LOCAL" ] && [ "$(cksum "$LOCAL" | cut -d ' ' -f1,2)" = "$sum" ]; then
      echo "补丁文件：已放入"
    else
      echo "补丁文件：已放入（和本地的不一样）"
    fi
    in_repo=1
  fi

  # 第二行：运行中的模型外挂有没有生效（/health 里有没有 tfpanel 这一段）
  if [ -z "$health" ] || [ "$health" = "NOHEALTH" ]; then
    echo "运行中的模型：读不到 /health"
    echo "不确定：读不到 /health，判断不了外挂有没有生效，先确认模型在不在跑"
    exit 0
  fi

  case "$health" in
  *'"tfpanel"'*)
    echo "运行中的模型：外挂已生效"
    hook=1
    ;;
  *)
    echo "运行中的模型：外挂未生效"
    hook=0
    ;;
  esac

  # 第三行：补丁文件的状态和运行中模型的状态一致就不必重启
  if [ "$in_repo" = "$hook" ]; then
    echo "状态一致，不需要重启"
  else
    echo "$RESTART"
  fi
  ;;
install)
  if [ ! -f "$LOCAL" ]; then
    echo "本地没有 $LOCAL，没有安装"
    exit 1
  fi
  dir=$(remote_deploy_dir) || dir=""
  if [ -z "$dir" ]; then
    echo "连不上 $HOST，不知道部署仓库在哪里，没有安装"
    exit 1
  fi
  if ! ssh "$HOST" </dev/null "test -d '$dir/patches'"; then
    echo "部署仓库里没有 patches 目录：$dir/patches，没有安装"
    exit 1
  fi
  scp -q "$LOCAL" "$HOST:$dir/patches/$PATCH"
  echo "$RESTART"
  ;;
remove)
  dir=$(remote_deploy_dir) || dir=""
  if [ -z "$dir" ]; then
    echo "连不上 $HOST，不知道部署仓库在哪里，没有动补丁文件"
    exit 1
  fi
  ssh "$HOST" </dev/null "rm -f '$dir/patches/$PATCH'"
  echo "$RESTART"
  ;;
*)
  usage
  exit 2
  ;;
esac
