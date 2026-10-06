#!/bin/sh
# 副屏仪表盘（TFPanel）：启动 / 停止 / 重启 / 查看副屏程序（在 Spark 上运行）。
#
# 用法：
#   tfpanel.sh start [程序参数...]   启动（已在运行就不重复启动）
#   tfpanel.sh stop                 停止
#   tfpanel.sh restart              重启
#   tfpanel.sh status               在运行就打印进程号、已运行时间、CPU 和内存占用
#
# start 后面的其余参数原样传给程序，例如：
#   tfpanel.sh start --state-dir /tmp/tfpanel-k/state

set -eu

# 程序目录 = 脚本所在目录的上一级（绝对路径）
DIR=$(cd "$(dirname "$0")/.." && pwd)

# 找进程：方括号写法避免匹配到 pgrep 自己；结尾的 ( |$) 避免匹配到 python3 -m panel.poller
find_pids() {
  pgrep -u "$(id -u)" -f "python3 -m pane[l]( |\$)" || true
}

usage() {
  echo "用法：$0 {start [程序参数...] | stop | restart | status}"
}

start_app() {
  pids=$(find_pids)
  if [ -n "$pids" ]; then
    echo "已在运行（进程号 $pids），不重复启动"
    exit 0
  fi

  # 环境变量没设时补上（桌面会话自己给了就不动）
  if [ -z "${DISPLAY:-}" ]; then
    export DISPLAY=:1
  fi
  if [ -z "${XAUTHORITY:-}" ]; then
    export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
  fi

  LOG=${TFPANEL_LOG:-$HOME/.local/state/tfpanel/tfpanel.log}
  mkdir -p "$(dirname "$LOG")"
  if [ -f "$LOG" ]; then
    sz=$(wc -c < "$LOG")
    if [ "$sz" -gt 1048576 ]; then
      : > "$LOG"          # 超过 1 MB，先清空
    fi
  fi

  cd "$DIR"
  # shellcheck disable=SC2086
  setsid nohup python3 -m panel "$@" >> "$LOG" 2>&1 </dev/null &

  sleep 1
  pid=$(find_pids)
  if [ -n "$pid" ]; then
    echo "已启动（进程号 $pid）"
  else
    tail -20 "$LOG"
    exit 1
  fi
}

stop_app() {
  pids=$(find_pids)
  if [ -z "$pids" ]; then
    echo "没有在运行"
    return 0
  fi
  # 先温和地停（SIGTERM），最多等 3 秒，还活着再强制
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  i=0
  while [ "$i" -lt 3 ]; do
    sleep 1
    pids=$(find_pids)
    if [ -z "$pids" ]; then
      break
    fi
    i=$((i + 1))
  done
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
  fi
  echo "已停止"
  return 0
}

status_app() {
  pids=$(find_pids)
  if [ -z "$pids" ]; then
    echo "没有在运行"
    return 1
  fi
  for p in $pids; do
    # etimes=已运行秒数 pcpu=CPU 占用% rss=内存 KB
    ps -o pid,etimes,pcpu,rss,cmd -p "$p"
  done
  return 0
}

case "${1:-}" in
  start)
    shift
    start_app "$@"
    ;;
  stop)
    stop_app
    ;;
  restart)
    shift
    stop_app
    sleep 1
    start_app "$@"
    ;;
  status)
    status_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
