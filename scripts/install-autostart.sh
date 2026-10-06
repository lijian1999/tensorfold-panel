#!/bin/sh
# 在 Spark 上安装 / 移除副屏仪表盘的开机启动项（GNOME 自启动目录里的 tfpanel.desktop）。
#
# 用法（在 Spark 上、从同步过去的 ~/tfpanel/ 里执行）：
#   ~/tfpanel/scripts/install-autostart.sh            # 安装
#   ~/tfpanel/scripts/install-autostart.sh --remove   # 移除
#
# 环境变量：
#   TFPANEL_AUTOSTART_DIR  启动项目录，默认 $HOME/.config/autostart
#
# 只写启动项文件，不改系统设置；自动登录要自己执行一条带管理员密码的命令。

set -eu

AUTOSTART_DIR=${TFPANEL_AUTOSTART_DIR:-$HOME/.config/autostart}
# 程序目录 = 脚本所在目录的上一级
APP_DIR=$(cd "$(dirname "$0")/.." && pwd)

case ${1:-} in
--remove)
  rm -f "$AUTOSTART_DIR/tfpanel.desktop"
  echo "已移除开机启动项"
  exit 0
  ;;
"") : ;;
*)
  echo "用法：$0 [--remove]"
  exit 2
  ;;
esac

mkdir -p "$AUTOSTART_DIR"
cat >"$AUTOSTART_DIR/tfpanel.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=TFPanel 副屏仪表盘
Comment=在拓展坞副屏上显示推理引擎的运行状态
Exec=$APP_DIR/scripts/tfpanel.sh start
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF

echo "已安装开机启动项：$AUTOSTART_DIR/tfpanel.desktop"

# 自动登录没开的话，重启后副屏不会自己亮起来；这里只检查、不修改
CONF=/etc/gdm3/custom.conf
if [ ! -r "$CONF" ]; then
  echo "自动登录：无法检查（读不了 $CONF）"
  exit 0
fi

if grep -Eiq '^AutomaticLoginEnable[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$CONF"; then
  echo "自动登录：已开启"
else
  echo "还需要开启自动登录（要输入管理员密码，请你自己执行）："
  echo "  sudo sed -i 's/^#\\? *AutomaticLoginEnable *=.*/AutomaticLoginEnable = true/; s/^#\\? *AutomaticLogin *=.*/AutomaticLogin = $(id -un)/' $CONF"
fi
