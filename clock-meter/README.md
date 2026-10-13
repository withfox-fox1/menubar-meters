# ClockMeter

メニューバーに日付（`10/12(月)`）と 24 時間表記の時刻（`12:04`）を縦 2 段で表示する macOS アプリ。
メニューバーの省スペース化のため、標準の時計はアナログ表示（小さなアイコン）にしている。

- 更新：毎分 0 秒、スリープ復帰・時刻/タイムゾーン変更時に即時
- クリック：完全な日時、日付と時刻の設定、ログイン時に起動、終了

## ビルド・インストール
```
./build.sh install
```

## 関連するシステム設定（2026-10-12 に変更）
| 設定 | 変更内容 | 元に戻す |
|---|---|---|
| 標準の時計をアナログに | `defaults write com.apple.menuextra.clock IsAnalog -bool true` | `... IsAnalog -bool false` |
| メニューバーの項目間隔 | `defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6` | `defaults -currentHost delete -globalDomain NSStatusItemSpacing` |
| 項目の選択時の余白 | `defaults -currentHost write -globalDomain NSStatusItemSelectionPadding -int 6` | `defaults -currentHost delete -globalDomain NSStatusItemSelectionPadding` |

いずれも `killall ControlCenter SystemUIServer` と各メニューバーアプリの再起動（確実なのはログアウト→ログイン）で反映される。
