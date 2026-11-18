#!/bin/bash
#
# uc 安装脚本
#
#   ./install.sh            安装命令到 ~/bin/uc
#   ./install.sh --agent    同时安装登录自启的守候服务（唤醒后自动重置）
#   ./install.sh --uninstall 卸载
#

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
DEST="$BIN_DIR/uc"
PLIST="$HOME/Library/LaunchAgents/local.uc.watch.plist"
LOG_FILE="$HOME/Library/Logs/uc-watch.log"
LABEL="local.uc.watch"

uninstall() {
  if [ -f "$PLIST" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已移除守候服务"
  fi
  if [ -f "$DEST" ]; then
    rm -f "$DEST"
    echo "已删除 $DEST"
  fi
  echo "卸载完成"
  exit 0
}

install_agent() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST</string>
        <string>watch</string>
        <string>20</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_FILE</string>
    <key>StandardErrorPath</key>
    <string>$LOG_FILE</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "守候服务已启动（日志：$LOG_FILE）"
  else
    echo "守候服务已写入 $PLIST"
    echo
    echo "当前环境无法立即注册（launchctl 被限制），但它在下次登录时会自动加载。"
    echo "想马上生效，在「终端」里执行这一行："
    echo
    echo "  launchctl bootstrap gui/\$(id -u) \"$PLIST\""
    echo
  fi
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
esac

mkdir -p "$BIN_DIR"
install -m 755 "$SRC_DIR/uc" "$DEST"
echo "已安装：$DEST"

# 确认 PATH 里有 ~/bin
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo
     echo "提示：$BIN_DIR 不在当前 PATH 中，请把下面这行加进 ~/.zshrc："
     echo "  export PATH=\"\$HOME/bin:\$PATH\"" ;;
esac

if [ "${1:-}" = "--agent" ]; then
  install_agent
fi

echo
echo "试一下：uc"
