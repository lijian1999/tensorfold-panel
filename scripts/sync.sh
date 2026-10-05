#!/bin/sh
# 把 MacBook Pro 上的仓库内容同步到 Spark 上的副屏程序目录。
#
# 用法（在 MacBook Pro 上执行）：
#   scripts/sync.sh                        同步到 spark:~/tfpanel/
#   TFPANEL_DEST=/tmp/tfpanel-j scripts/sync.sh    同步到别处（演练用）
#
# 环境变量：
#   TFPANEL_HOST  主机名，默认 spark（SSH 里配好的名字）
#   TFPANEL_DEST  Spark 上的目标目录，默认 tfpanel；相对路径算在主目录下，也可以给绝对路径
#
# 只同步 panel、fixtures、scripts、hook 四个目录，不同步 docs 和 .git。

set -eu

# 从脚本自己的位置找仓库根目录，在别的目录里调用也能用
cd "$(dirname "$0")/.."

HOST=${TFPANEL_HOST:-spark}
DEST=${TFPANEL_DEST:-tfpanel}

ssh "$HOST" "mkdir -p '$DEST'"

for d in panel fixtures scripts hook; do
  if [ -d "$d" ]; then
    rsync -a --delete --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store "$d" "$HOST:$DEST/"
  else
    echo "跳过：仓库里没有 $d"
  fi
done

echo "已同步到 $HOST:$DEST"
