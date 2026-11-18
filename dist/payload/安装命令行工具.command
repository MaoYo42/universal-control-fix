#!/bin/bash
#
# 安装命令行工具（uc + ucdisplay）
#
# 双击运行。会把两个可执行文件装到 ~/bin，并可选地装上开机守候服务。
#

set -u

cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"
SRC="$HERE/命令行工具"
BIN_DIR="$HOME/bin"

echo
echo "════════════════════════════════════════════"
echo "  通用控制自愈工具 — 命令行部分"
echo "════════════════════════════════════════════"
echo

if [ ! -f "$SRC/uc" ]; then
  echo "✗ 找不到 命令行工具/uc，安装包可能不完整。"
  echo "  按回车关闭。"
  read -r _
  exit 1
fi

# ── 1. 解除 UCMenu.app 的隔离标记 ──
# 未签名的应用从网上下载后会被 Gatekeeper 拦住，双击只报「已损坏」。
if [ -d "$HERE/UCMenu.app" ]; then
  xattr -dr com.apple.quarantine "$HERE/UCMenu.app" 2>/dev/null
  echo "· 已解除 UCMenu.app 的下载隔离标记"
fi

# ── 2. 装命令行工具 ──
mkdir -p "$BIN_DIR"
if [ -f "$BIN_DIR/uc" ]; then
  cp "$BIN_DIR/uc" "$BIN_DIR/uc.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
  echo "· 已有旧版 uc，已备份"
fi
install -m 755 "$SRC/uc" "$BIN_DIR/uc" && echo "· 已安装 $BIN_DIR/uc"
if [ -f "$SRC/ucdisplay" ]; then
  install -m 755 "$SRC/ucdisplay" "$BIN_DIR/ucdisplay" && echo "· 已安装 $BIN_DIR/ucdisplay"
fi

# ── 3. PATH ──
case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "· $BIN_DIR 已在 PATH 中" ;;
  *)
    echo
    echo "⚠ $BIN_DIR 不在 PATH 里。把下面这行加进 ~/.zshrc："
    echo
    echo "    export PATH=\"\$HOME/bin:\$PATH\""
    echo
    ;;
esac

# ── 4. 可选：守候服务 ──
echo
printf "要不要装开机守候服务？（掉线/唤醒后自动重置通用控制）[y/N] "
read -r ans
case "$ans" in
  y|Y|yes|YES)
    "$BIN_DIR/uc" agent on
    ;;
  *)
    echo "· 跳过守候服务（以后想装：uc agent on）"
    ;;
esac

echo
echo "────────────────────────────────────────────"
echo "装好了。试一下："
echo
echo "    uc              # 体检报告"
echo "    uc arrange      # 看显示器排列"
echo "    uc --help       # 全部命令"
echo
echo "菜单栏程序：把 UCMenu.app 拖进「应用程序」文件夹，双击运行。"
echo "────────────────────────────────────────────"
echo
echo "按回车关闭这个窗口。"
read -r _
