# セットアップ指示書（Claude Code向け）

このファイルは、別の Mac にメニューバー用の自作アプリ3つを導入するための自己完結した指示書です。
ユーザーからこのファイル（またはこのリポジトリの URL）を渡されて「これで実装して」と言われたら、以下を上から順に実施してください。

| アプリ | メニューバーの表示 |
|---|---|
| ClockMeter | 日付 `10/12(月)` ／ 24時間表記の時刻 `12:04` の縦2段（左端に区切り線） |
| BatteryMeter | 電池アイコン＋残量 `%` ／ 残り時間 `5h44m`（充電中は `⚡︎1h12m`）の縦2段 |
| BluetoothMeter | 接続中イヤホン等の残量（`OpenRun`／`80%`、左右独立型は `L 80%`／`R 75%`）。なければ ᛒ のみ |

あわせて次のシステム設定を変更する（`./uninstall.sh` で導入前の値に戻せる）:
- 標準のバッテリー／Bluetooth アイコンを非表示（上の自作アプリで置き換えるため）
- 標準の時計をアナログ表示（小さいアイコン）に
- メニューバー項目の間隔を詰める（`NSStatusItemSpacing=6` / `NSStatusItemSelectionPadding=6`）

## 前提（作業前に把握しておくこと）

- **必要なもの**: macOS 13 以降、Xcode Command Line Tools（`swiftc`）。Xcode 本体・Homebrew・Apple ID は不要。
  - 開発・動作確認は macOS 27（Apple Silicon）で実施。それ以外は未検証なので、違いがあればユーザーに伝えてから進める。
- ビルドは各アプリの `build.sh`（`swiftc` で単一ファイルをコンパイル）。Xcode プロジェクトは無い。
- 署名: そのMacに Apple Development 証明書があればそれで、なければアドホック署名（`-`）になる。どちらでも動く。証明書の作成は不要。
- 内蔵バッテリーのない Mac（iMac / Mac mini 等）では BatteryMeter と標準バッテリーアイコンの非表示は自動でスキップされる。
- 3アプリとも初回起動時にログイン項目へ自動登録される（各アプリのメニューから切替可）。
- **BluetoothMeter の残量取得は「自分自身を `--dump-battery` で子プロセス起動して読む」方式。** 同一プロセスだと再接続後に残量が 0 のまま更新されないため（実測）。コードを「最適化」してこの仕組みを外さないこと。

## 手順

### 1. 環境の確認

```bash
sw_vers -productVersion
uname -m
xcode-select -p && xcrun --find swiftc
```

- `xcode-select -p` が失敗する場合: `xcode-select --install` を実行し、表示されるダイアログでインストールするようユーザーに依頼する（GUI 操作が必要）。完了を待ってから続行。
- macOS が 13 未満なら中断してユーザーに伝える。

### 2. ソースの取得

リポジトリは公開（public）なのでログイン不要。

```bash
cd ~
if [ -d menubar-meters/.git ]; then git -C menubar-meters pull --ff-only; else git clone https://github.com/withfox-fox1/menubar-meters.git; fi
cd ~/menubar-meters
```

### 3. 導入前の状態確認（任意だが推奨）

既に同名アプリや同様のメニューバーアプリが入っていないか確認し、あればユーザーに伝える:

```bash
ls -d /Applications/{ClockMeter,BatteryMeter,BluetoothMeter}.app 2>/dev/null
```

### 4. インストール

```bash
./install.sh
```

- システム設定を変えたくないとユーザーが言った場合は `./install.sh --apps-only`。
- 成功すると最後に「完了。」と表示され、メニューバーに時計・バッテリー・Bluetooth の表示が出る。
- 変更前のシステム設定は `~/Library/Application Support/MenubarMeters/settings-backup.txt` に保存される（初回のみ）。

### 5. 動作確認

```bash
pgrep -lx "ClockMeter|BatteryMeter|BluetoothMeter"
```

- 起動中のプロセスが表示されること（内蔵バッテリーのない Mac では BatteryMeter は無くてよい）。
- 見た目の確認はユーザーに依頼する。確認ポイント:
  - 時計：日付と24時間表記の時刻が2段で出ている
  - バッテリー：%と残り時間が出ている（電源を抜いた直後は「計算中」→ 約30秒〜数分で時間表示）
  - Bluetooth：イヤホン等を接続すると残量が出る
- **Bluetooth のアクセス許可ダイアログ**が出たら「許可」を押してもらう。拒否した場合は
  システム設定 → プライバシーとセキュリティ → Bluetooth で BluetoothMeter をオンにする。

### 6. ユーザーへの案内

- 項目間隔の変更をすべてのアプリに反映するには、一度 **ログアウト → ログイン** が必要（強制しない。ユーザーに伝えるだけ）。
- 並び順を変えたいときは **⌘（command）キーを押しながらアイコンをドラッグ**。位置は記憶される。
- メニューバーが満杯だとノッチの裏に隠れて見えないアイコンが出ることがある。その場合は不要なメニューバーアプリを減らすか ⌘ドラッグで並べ替える。

## 今後コードを更新したとき

```bash
cd ~/menubar-meters && git pull --ff-only && ./install.sh
```

（設定のバックアップは初回の値を保持したまま上書きしない）

## アンインストール（元に戻す）

```bash
cd ~/menubar-meters && ./uninstall.sh
```

3アプリを `/Applications` から削除し、システム設定を導入前の値に戻す。間隔の復元はログアウト→ログインで全アプリに反映。

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `swiftc` のビルドエラー | `xcode-select -p` の出力先を確認。Xcode と CLT が混在して古い SDK を指している場合は `sudo xcode-select -s /Library/Developer/CommandLineTools` をユーザーに提案（sudo なので実行前に確認） |
| アイコンが出ない | メニューバー満杯で隠れている可能性。`pgrep` で起動を確認し、他のアイコンを ⌘ドラッグで外す等をユーザーに相談 |
| Bluetooth 残量が出ない | 機器が残量通知に非対応、またはアクセス許可がオフ。macOS の非公開プロパティを使っているため OS 更新で取れなくなる可能性もある（その場合も表示が ᛒ になるだけで動作は継続） |
| 標準アイコンが消えない | `killall ControlCenter` を実行。それでもダメなら システム設定 → コントロールセンター で該当項目を「メニューバーに表示しない」に |
