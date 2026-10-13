#!/bin/zsh
# install.sh で導入したアプリを削除し、メニューバーのシステム設定を導入前の値に戻す。
#   ./uninstall.sh
set -euo pipefail

BACKUP="$HOME/Library/Application Support/MenubarMeters/settings-backup.txt"

for app in BluetoothMeter BatteryMeter ClockMeter; do
  if [[ -d "/Applications/$app.app" ]]; then
    # ログイン項目の登録はアプリ削除後に macOS が自動で無効化する
    pkill -x "$app" 2>/dev/null || true
    rm -rf "/Applications/$app.app"
    echo "削除: /Applications/$app.app"
  fi
done

# 値を戻す。UNSET（導入前は未設定）なら削除する
restore() { # restore <host|user> <ドメイン> <キー> <型> <値>
  local -a host=(); [[ "$1" == host ]] && host=(-currentHost)
  local domain="$2" key="$3" type="$4" value="$5"
  if [[ "$value" == "UNSET" ]]; then
    defaults "${host[@]}" delete "$domain" "$key" 2>/dev/null || true
  else
    # defaults read は真偽値を 1/0 で返すため、-bool 用に変換する
    [[ "$type" == -bool ]] && { [[ "$value" == 1 ]] && value=true || value=false; }
    defaults "${host[@]}" write "$domain" "$key" "$type" "$value"
  fi
}

if [[ -f "$BACKUP" ]]; then
  typeset -A old
  while IFS='=' read -r k v; do old[$k]=$v; done < "$BACKUP"
  restore host com.apple.controlcenter Battery -int "${old[Battery]}"
  restore host com.apple.controlcenter Bluetooth -int "${old[Bluetooth]}"
  restore user com.apple.menuextra.clock IsAnalog -bool "${old[IsAnalog]}"
  restore host -globalDomain NSStatusItemSpacing -int "${old[NSStatusItemSpacing]}"
  restore host -globalDomain NSStatusItemSelectionPadding -int "${old[NSStatusItemSelectionPadding]}"
  rm -f "$BACKUP"
  echo "システム設定を導入前の値に戻しました。"
else
  # バックアップがない場合は macOS の標準状態に戻す
  defaults -currentHost write com.apple.controlcenter Battery -int 2
  defaults -currentHost write com.apple.controlcenter Bluetooth -int 2
  defaults write com.apple.menuextra.clock IsAnalog -bool false
  defaults -currentHost delete -globalDomain NSStatusItemSpacing 2>/dev/null || true
  defaults -currentHost delete -globalDomain NSStatusItemSelectionPadding 2>/dev/null || true
  echo "バックアップがないため、macOS の標準状態に戻しました。"
fi

killall ControlCenter SystemUIServer 2>/dev/null || true
echo "完了。項目間隔を全アプリに反映するには、一度ログアウト→ログインしてください。"
