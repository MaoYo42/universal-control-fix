#!/bin/bash
#
# 打 DMG 分发包
#
#   ./make-dmg.sh            生成 dist/UniversalControlFix-<版本>.dmg
#   ./make-dmg.sh --keep     保留中间目录（排查用）
#
# 产物结构：
#   Universal Control Fix/
#   ├── UCMenu.app                 菜单栏程序（通用二进制）
#   ├── Applications -> /Applications
#   ├── 安装命令行工具.command
#   ├── 命令行工具/{uc,ucdisplay}
#   └── 使用说明.txt
#

set -e

DIST_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIST_DIR/.." && pwd)"
VERSION=$(grep '^VERSION=' "$ROOT/uc" | head -1 | cut -d'"' -f2)

if [ -z "$VERSION" ]; then
  echo "读不到版本号（$ROOT/uc 里的 VERSION=）"
  exit 1
fi

VOLNAME="Universal Control Fix"
STAGE="$DIST_DIR/stage"
DMG="$DIST_DIR/UniversalControlFix-$VERSION.dmg"

echo "版本：$VERSION"
echo

# ── 1. 编译菜单栏程序 ──
echo "① 编译 UCMenu"
"$ROOT/menu/build.sh" 2>&1 | sed 's/^/   /'

# ── 2. 准备暂存目录 ──
echo
echo "② 准备暂存目录"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$ROOT/menu/build/UCMenu.app" "$STAGE/"
echo "   UCMenu.app  ($(lipo -archs "$STAGE/UCMenu.app/Contents/MacOS/UCMenu"))"

ln -s /Applications "$STAGE/Applications"

mkdir -p "$STAGE/命令行工具"
install -m 755 "$ROOT/uc" "$STAGE/命令行工具/uc"
if [ -x "$ROOT/tools/ucdisplay" ]; then
  install -m 755 "$ROOT/tools/ucdisplay" "$STAGE/命令行工具/ucdisplay"
  echo "   命令行工具/uc, ucdisplay"
else
  echo "   命令行工具/uc（缺 ucdisplay，arrange 功能不可用）"
fi

install -m 755 "$DIST_DIR/payload/安装命令行工具.command" "$STAGE/"
install -m 644 "$DIST_DIR/payload/使用说明.txt" "$STAGE/"
echo "   安装命令行工具.command, 使用说明.txt"

# 去掉扩展属性，免得 DMG 里带着本机的 quarantine / 资源叉
xattr -cr "$STAGE" 2>/dev/null || true

# ── 3. 打 DMG ──
echo
echo "③ 打包 DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ "$DMG" 2>&1 | tail -3

if [ ! -f "$DMG" ]; then
  echo "打包失败"
  exit 1
fi

# 给 DMG 本身签名（ad-hoc），至少保证挂载时结构完整
codesign --force --sign - "$DMG" 2>/dev/null || true

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

echo
echo "────────────────────────────────────────────"
echo "  $DMG"
echo "  大小 $SIZE"
echo "  sha256 $SHA"
echo "────────────────────────────────────────────"

if [ "${1:-}" != "--keep" ]; then
  rm -rf "$STAGE"
fi

echo
echo "试挂载：open \"$DMG\""
