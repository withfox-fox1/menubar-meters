# BatteryMeter

メニューバーに「電池アイコン＋残量%／残り稼働時間（2段）」を表示する macOS アプリ。

## 表示仕様
- 上段：残量 %
- 下段：バッテリー駆動中は残り稼働時間（`4h42m`）、計算中は `計算中`（充電中は `⚡︎計算中`）
  - 充電中：満充電までの時間（`⚡︎1h12m`）／満充電：`満充電`
  - 電源接続中だが充電されず放電している（低出力のモバイルバッテリー等）：プラグマーク＋残り稼働時間（電池アイコンは稲妻なし）
  - 電源接続中で放電もしていない（最適化充電の保留等）：`接続中`
- macOS が時間を返さない場合は、AppleSmartBattery の電流値（直近2分の平均、30秒分たまるまでは「計算中」）と残り容量から自前で推定する（メニューに「電流値から推定」と表示）
- 更新：電源状態の変化を IOKit 通知で即時反映＋5秒ごとの定期更新
- クリックで詳細・バッテリー設定・ログイン時に起動の切替・終了

## ビルド・インストール
```
./build.sh install   # build/ に作成 → /Applications に上書き → 起動
```
初回起動時にログイン項目へ自動登録する（メニューから切替可）。

## 標準のバッテリーアイコンを戻す／消す
- 消す：`defaults -currentHost write com.apple.controlcenter Battery -int 8 && killall ControlCenter`
- 戻す：`defaults -currentHost write com.apple.controlcenter Battery -int 2 && killall ControlCenter`
  （システム設定 → コントロールセンター → バッテリー からも変更可）
