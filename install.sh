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
DEST_DISPLAY="$BIN_DIR/ucdisplay"
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
  if [ -f "$DEST_DISPLAY" ]; then
    rm -f "$DEST_DISPLAY"
    echo "已删除 $DEST_DISPLAY"
  fi
  echo "卸载完成"
  exit 0
}

# 守候服务只有一份实现，在 uc 里（uc agent on|off）。
# 这里不重复写 plist，免得两边字段漂移。
install_agent() {
  "$DEST" agent on
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
esac

mkdir -p "$BIN_DIR"
install -m 755 "$SRC_DIR/uc" "$DEST"
echo "已安装：$DEST"

# 显示器排列组件（可选，缺了不影响体检/重置，只是没有 uc arrange）
if [ -x "$SRC_DIR/tools/ucdisplay" ]; then
  install -m 755 "$SRC_DIR/tools/ucdisplay" "$DEST_DISPLAY"
  echo "已安装：$DEST_DISPLAY"
elif command -v swiftc >/dev/null 2>&1 && [ -f "$SRC_DIR/tools/ucdisplay.swift" ]; then
  # 通用二进制：x86_64 切片的目标要定在 14.0，CLT 的 Swift 兼容库只带 arm64
  _t=$(mktemp -d)
  if swiftc -O -target arm64-apple-macos12.0 -o "$_t/a" "$SRC_DIR/tools/ucdisplay.swift" \
       -framework CoreGraphics -framework AppKit 2>/dev/null \
     && swiftc -O -target x86_64-apple-macos14.0 -o "$_t/b" "$SRC_DIR/tools/ucdisplay.swift" \
       -framework CoreGraphics -framework AppKit 2>/dev/null \
     && lipo -create "$_t/a" "$_t/b" -output "$DEST_DISPLAY" 2>/dev/null; then
    chmod 755 "$DEST_DISPLAY"
    echo "已编译并安装：$DEST_DISPLAY（$(lipo -archs "$DEST_DISPLAY")）"
  else
    echo "提示：ucdisplay 编译失败，uc arrange 相关功能不可用"
  fi
  rm -rf "$_t"
else
  echo "提示：未找到 ucdisplay，uc arrange 相关功能不可用"
fi

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
