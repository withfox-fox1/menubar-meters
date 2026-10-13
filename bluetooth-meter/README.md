# BluetoothMeter

標準の Bluetooth メニューバーアイコンを置き換え、接続中のイヤホン等の残量を表示する macOS アプリ。

## 表示仕様
- 残量の取れる接続中デバイスがない：Bluetooth ロゴ（ᛒ）のみ
- ある：デバイスアイコン＋2段表示（オーディオ機器を優先して 1 台）
  - 左右一体型：上段 短縮名（例 `OpenRun`）／下段 `80%`
  - 左右独立型：上段 `L 80%`／下段 `R 75%`
- クリック：ペアリング済みデバイス一覧（残量付き、クリックで接続/切断）、Bluetooth設定、ログイン時に起動、終了
- 更新：接続/切断通知で即時、残量は接続後 2・8・20 秒と 30 秒ごと

## 残量の取得方法（重要）
- `IOBluetoothDevice` の非公開プロパティ `batteryPercentSingle/Left/Right/Case` を読む。将来の macOS で取れなくなった場合は残量が出ないだけで動作は継続する。
- 同一プロセス内ではプロセス起動時の値から更新されず、切断→再接続後は 0 のままになる（2026-10-12 実測）。
  そのため取得のたびに自分自身を `--dump-battery` 付きで別プロセス起動して最新値を JSON で受け取る。
- 動作確認済み：Shokz OpenRun Pro 2（single）。Sony WF-1000XM5 は左右別ではなく single の1値のみ取得される（2026-10-13 時点、左右表示は見送り）。

## ビルド・インストール
```
./build.sh install   # build/ に作成 → /Applications に上書き → 起動
```

## 標準の Bluetooth アイコンを戻す／消す
- 消す：`defaults -currentHost write com.apple.controlcenter Bluetooth -int 8 && killall ControlCenter`
- 戻す：`defaults -currentHost write com.apple.controlcenter Bluetooth -int 2 && killall ControlCenter`
