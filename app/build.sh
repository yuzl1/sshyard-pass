#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
PROJECT="${ROOT:h}"
APP="${APP_DIR:-$HOME/Applications}/SSHYard-密码获取器.app"
WORK="$ROOT/build"

rm -r "$WORK" 2>/dev/null || true
mkdir -p "$WORK"

echo "→ 编译解密工具"
cd "$PROJECT"
go build -trimpath -ldflags '-s -w' -o "$WORK/sshyard-pass" .

echo "→ 编译 Swift"
swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$WORK/SSHYardPass" "$ROOT/main.swift"

echo "→ 生成图标"
swift "$ROOT/makeicon.swift" "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for pair in "16:16" "32:16@2x" "32:32" "64:32@2x" "128:128" "256:128@2x" "256:256" "512:256@2x" "512:512" "1024:512@2x"; do
  px="${pair%%:*}"
  name="${pair##*:}"
  sips -z "$px" "$px" "$WORK/icon-1024.png" --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"

echo "→ 组装 App"
rm -r "$APP" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/SSHYardPass" "$APP/Contents/MacOS/SSHYardPass"
cp "$WORK/sshyard-pass" "$APP/Contents/Resources/sshyard-pass"
chmod +x "$APP/Contents/MacOS/SSHYardPass" "$APP/Contents/Resources/sshyard-pass"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

mkdir -p "$HOME/.local/bin"
cp "$WORK/sshyard-pass" "$HOME/.local/bin/sshyard-pass"
codesign --force -s - "$HOME/.local/bin/sshyard-pass"

echo "→ 本地签名（ad-hoc）"
codesign --force --deep -s - "$APP"
touch "$APP"

echo "完成：$APP"
echo "命令行：$HOME/.local/bin/sshyard-pass"
