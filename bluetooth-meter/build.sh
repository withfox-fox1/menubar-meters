#!/bin/zsh
# BluetoothMeter.app をビルドして署名する。
#   ./build.sh            → build/BluetoothMeter.app を作成
#   ./build.sh install    → さらに /Applications へ上書きコピーして起動
set -euo pipefail
cd "$(dirname "$0")"

APP=build/BluetoothMeter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 Sources/main.swift \
  -framework AppKit -framework IOBluetooth -framework ServiceManagement \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/BluetoothMeter"

cp Info.plist "$APP/Contents/Info.plist"

# Apple Development 証明書があればそれで、なければアドホック署名
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built: $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
  pkill -x BluetoothMeter 2>/dev/null || true
  rm -rf /Applications/BluetoothMeter.app
  cp -R "$APP" /Applications/
  open /Applications/BluetoothMeter.app
  echo "Installed: /Applications/BluetoothMeter.app"
fi
