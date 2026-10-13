# menubar-meters

macOS のメニューバーを省スペースにする自作アプリ3点セット。どれも縦2段・小さい文字で統一。

- **ClockMeter** — 日付／24時間表記の時刻（[clock-meter/](clock-meter/README.md)）
- **BatteryMeter** — 電池残量%／残り時間（[battery-meter/](battery-meter/README.md)）
- **BluetoothMeter** — 標準 Bluetooth アイコンの置き換え＋イヤホン残量（[bluetooth-meter/](bluetooth-meter/README.md)）

## インストール

必要なもの: macOS 13 以降、Xcode Command Line Tools（`xcode-select --install`）

```bash
git clone https://github.com/withfox-fox1/menubar-meters.git ~/menubar-meters
cd ~/menubar-meters
./install.sh              # アプリ導入＋メニューバー設定（標準アイコン非表示・時計アナログ化・間隔詰め）
./install.sh --apps-only  # アプリだけ入れる
```

元に戻す: `./uninstall.sh`

Claude Code に導入させる場合は [SETUP_PROMPT.md](SETUP_PROMPT.md) を渡して「これで実装して」と頼む。

## 個別にビルドする

```bash
./clock-meter/build.sh install   # ビルド → /Applications に上書き → 起動
```
