#!/bin/bash
#
# UCMenu 构建脚本
#
#   ./build.sh              编译并打包 build/UCMenu.app
#   ./build.sh --install    打包后装到 ~/Applications 并注册登录自启
#   ./build.sh --uninstall  移除
#
# 只需要 Command Line Tools，不需要 Xcode。
#
# 产物是通用二进制：
#   arm64   部署目标 macOS 12.0
#   x86_64  部署目标 macOS 14.0（CLT 的 Swift 兼容库只带 arm64 切片，
#           目标定在 12.0 会因缺 libswiftCompatibility56 链接失败）

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC_DIR/build"
APP="$BUILD/UCMenu.app"
DEST="$HOME/Applications/UCMenu.app"
PLIST="$HOME/Library/LaunchAgents/local.uc.menu.plist"
LABEL="local.uc.menu"
VERSION="1.3.3"

uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  pkill -f "UCMenu.app/Contents/MacOS/UCMenu" 2>/dev/null || true
  rm -rf "$DEST"
  echo "已移除 UCMenu（含登录自启）"
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

# ─────────────────────── 图标 ───────────────────────
#
# 用 SF Symbol 的 keyboard 画在圆角底板上，再转成 .icns。
# 没有设计资源，这样至少不会顶着一个通用空白图标。

make_icon() {
  local out="$1"
  local tmp; tmp=$(mktemp -d)
  local gen="$tmp/genicon.swift"

  cat > "$gen" <<'SWIFT'
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = CommandLine.arguments[1]

for s in sizes {
    let px = CGFloat(s)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // 圆角底板
    let inset = px * 0.06
    let rect = CGRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: px * 0.22,
                      cornerHeight: px * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.13, green: 0.16, blue: 0.22, alpha: 1),
        CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1),
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: px),
                           end: CGPoint(x: px, y: 0), options: [])
    ctx.restoreGState()

    // 描边
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
    ctx.setLineWidth(max(1, px * 0.012))
    ctx.strokePath()

    // 键盘符号
    let cfg = NSImage.SymbolConfiguration(pointSize: px * 0.50, weight: .regular)
    if let sym = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor(red: 0.45, green: 0.85, blue: 0.75, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let sz = tinted.size
        let target = CGRect(x: (px - sz.width) / 2,
                            y: (px - sz.height) / 2,
                            width: sz.width, height: sz.height)
        tinted.draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()

    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(s).png"))
    }
}
SWIFT

  swiftc -O -o "$tmp/genicon" "$gen" -framework AppKit 2>/dev/null || {
    rm -rf "$tmp"; return 1; }

  "$tmp/genicon" "$tmp" || { rm -rf "$tmp"; return 1; }

  local set="$tmp/UCMenu.iconset"
  mkdir -p "$set"
  for s in 16 32 128 256 512; do
    cp "$tmp/icon_$s.png" "$set/icon_${s}x${s}.png"
    cp "$tmp/icon_$((s*2)).png" "$set/icon_${s}x${s}@2x.png"
  done

  iconutil -c icns "$set" -o "$out" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

echo "编译…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# -parse-as-library：文件级 let 常量 + @main 入口共存的前提，
# 否则单文件编译会把它们判成 top-level code 而拒绝 @main
echo "  arm64…"
swiftc -O -parse-as-library -target arm64-apple-macos12.0 \
  -o "$TMPD/UCMenu-arm64" "$SRC_DIR/UCMenu.swift" -framework AppKit 2>&1 | head -20

echo "  x86_64…"
swiftc -O -parse-as-library -target x86_64-apple-macos14.0 \
  -o "$TMPD/UCMenu-x86_64" "$SRC_DIR/UCMenu.swift" -framework AppKit 2>&1 | head -20

if [ ! -f "$TMPD/UCMenu-arm64" ] || [ ! -f "$TMPD/UCMenu-x86_64" ]; then
  echo "编译失败"
  exit 1
fi

lipo -create "$TMPD/UCMenu-arm64" "$TMPD/UCMenu-x86_64" \
  -output "$APP/Contents/MacOS/UCMenu"
echo "  架构：$(lipo -archs "$APP/Contents/MacOS/UCMenu")"

echo "图标…"
if make_icon "$APP/Contents/Resources/UCMenu.icns"; then
  echo "  已生成 UCMenu.icns"
  ICON_KEY='    <key>CFBundleIconFile</key>           <string>UCMenu</string>'
else
  echo "  跳过（生成失败）"
  ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>UCMenu</string>
    <key>CFBundleDisplayName</key>     <string>通用控制</string>
    <key>CFBundleIdentifier</key>      <string>local.uc.menu</string>
    <key>CFBundleExecutable</key>      <string>UCMenu</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
$ICON_KEY
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>MIT License</string>
</dict>
</plist>
EOF

echo "签名…"
codesign --force --sign - "$APP" 2>&1 | head -5 || true
codesign --verify --deep --strict "$APP" 2>&1 | head -5 || true

echo "已生成：$APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications" "$(dirname "$PLIST")"

  # 必须先停掉旧实例再动 bundle。
  # 反过来做的话，正在运行的进程会在签名被替换的瞬间收到
  # SIGKILL (Code Signature Invalid / Launch Constraint Violation)，
  # 看起来像崩溃，实际是升级流程自己把进程杀了。
  pkill -f "UCMenu.app/Contents/MacOS/UCMenu" 2>/dev/null || true
  sleep 0.5

  rm -rf "$DEST"
  cp -R "$APP" "$DEST"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/UCMenu</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "已启动，登录时自动运行"
  else
    echo "已写入 $PLIST"
    echo "当前环境无法立即注册（launchctl 被限制），下次登录会自动加载。"
    echo "想马上生效，在终端执行："
    echo "  launchctl bootstrap gui/\$(id -u) \"$PLIST\""
    open "$DEST" 2>/dev/null || true
  fi
  echo "已安装到：$DEST"
else
  echo "试运行：open \"$APP\""
fi
