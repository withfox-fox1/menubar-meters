#!/bin/zsh
# メニューバー3アプリ（ClockMeter / BatteryMeter / BluetoothMeter）を一括でビルド・インストールし、
# メニューバーのシステム設定（標準アイコン非表示・時計アナログ化・項目間隔）を適用する。
#
#   ./install.sh               → アプリ導入＋システム設定の適用
#   ./install.sh --apps-only   → アプリ導入のみ（システム設定は変更しない）
#
# 何度実行してもよい（コード更新後の再インストールにも使う）。
# システム設定の変更前の値は初回のみ BACKUP に保存し、uninstall.sh で元に戻す。
set -euo pipefail
cd "$(dirname "$0")"

APPS_ONLY=0
[[ "${1:-}" == "--apps-only" ]] && APPS_ONLY=1

BACKUP_DIR="$HOME/Library/Application Support/MenubarMeters"
BACKUP="$BACKUP_DIR/settings-backup.txt"

# ---- 1. 前提チェック ----
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if (( MAJOR < 13 )); then
  echo "エラー: macOS 13 以降が必要です（現在 $(sw_vers -productVersion)）" >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "エラー: Xcode Command Line Tools がありません。" >&2
  echo "  xcode-select --install を実行し、表示されるダイアログでインストールしてから再実行してください。" >&2
  exit 1
fi

HAS_BATTERY=0
pmset -g batt | grep InternalBattery >/dev/null && HAS_BATTERY=1

# ---- 2. ビルド＆インストール ----
# メニューバーでは後から起動したものが左に並ぶため、時計 → バッテリー → Bluetooth の順に起動する
./clock-meter/build.sh install
if (( HAS_BATTERY )); then
  ./battery-meter/build.sh install
else
  echo "内蔵バッテリーがない Mac のため BatteryMeter はスキップしました。"
fi
./bluetooth-meter/build.sh install

if (( APPS_ONLY )); then
  echo "完了（アプリのみ）。"
  exit 0
fi

# ---- 3. システム設定 ----
read_or_unset() { defaults "$@" 2>/dev/null || echo "UNSET"; }

if [[ ! -f "$BACKUP" ]]; then
  mkdir -p "$BACKUP_DIR"
  {
    echo "Battery=$(read_or_unset -currentHost read com.apple.controlcenter Battery)"
    echo "Bluetooth=$(read_or_unset -currentHost read com.apple.controlcenter Bluetooth)"
    echo "IsAnalog=$(read_or_unset read com.apple.menuextra.clock IsAnalog)"
    echo "NSStatusItemSpacing=$(read_or_unset -currentHost read -globalDomain NSStatusItemSpacing)"
    echo "NSStatusItemSelectionPadding=$(read_or_unset -currentHost read -globalDomain NSStatusItemSelectionPadding)"
  } > "$BACKUP"
  echo "変更前の設定を保存しました: $BACKUP"
fi

# 標準アイコンを非表示（8 = メニューバーに表示しない）
(( HAS_BATTERY )) && defaults -currentHost write com.apple.controlcenter Battery -int 8
defaults -currentHost write com.apple.controlcenter Bluetooth -int 8
# 標準の時計はアナログ（小さいアイコン）に
defaults write com.apple.menuextra.clock IsAnalog -bool true
# メニューバー項目の間隔を詰める（全アプリへの反映にはログアウト→ログインが必要）
defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6
defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 6

killall ControlCenter SystemUIServer 2>/dev/null || true

echo ""
echo "完了。項目間隔の変更を全アプリに反映するには、一度ログアウト→ログインしてください。"
echo "元に戻すには ./uninstall.sh を実行します。"
