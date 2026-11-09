# scripts/（Windows PC 用 PowerShell）

利用者向けの説明は README.md の「録画データを PC へコピーする」以降。ここの開発者向けの詳細は scripts/README.md。

## 守ること
- **Windows PowerShell 5.1 と PowerShell 7 の両方で動かす。** 変更後は両方で実行して確かめる（`powershell` と `pwsh`）
- 日本語は書かない（スクリプト内は ASCII。5.1 は BOM なしの UTF-8 を ANSI として読む）。ログ・`.prom` は BOM なし UTF-8 で書く
- 終了は必ず `Complete-Run`（`Copy-Recordings.ps1`）を通す。直接 `exit` するとメトリクスが書かれない
- `-WhatIf` ではファイルを書かない（ログ・メトリクス・コピー・削除のどれも）
- `exit_reason` の値と `copy_recordings_*` の名前は Terraform が使う契約。増減は Mac 側と合わせる（ルートの CLAUDE.md）
- `Copy-Recordings.ps1` の中でスリープしない。`-SleepAfter` は別タスク（`Sleep-Computer.ps1`）を起動するだけ
- SYSTEM のタスクで動くスクリプトは、失敗が画面に出ない。起動直後にログを 1 行書き、`trap` で失敗をログに残す（`Sleep-Computer.ps1` が最初の実機の実行で何も残さず、原因を後から追えなかった）
- ドキュメントに Windows のパス（`C:\projects\MyProductsaspberry-pi\...`）を書くとき、スクリプトや here-document 経由で書くと `` `	` `
` が制御文字になって消える（README の `SleepAfterCopy` 登録例で `raspberry-pi` の `` が欠け、タスクが 2 回続けて起動に失敗した）。書いたあとに `grep` でパスを確認し、Edit ツールで直す
- 「スリープしなかった」と言われたら、まず `copy-YYYYMMDD.log` の有無を見る。ログがない日は、スリープ以前に `CopyRecordings` が起動していない（タスクスケジューラの履歴 ID 129/114 と、System ログの復帰イベントで確かめる）。スリープ自体はイベント（Kernel-Power 187・42）と Power-Troubleshooter ID 1 の `SleepTime` で、実際に入ったか分かる
- 電源・復帰まわりの文言は環境で違う。タイマー復帰は、この PC では `Device -ACPI Wake Alarm`（タスク名は出ない）。推測で書かず、システムログの実物（`Get-WinEvent`、Power-Troubleshooter ID 1）で確かめる

## 検証の落とし穴
- **`.env.ps1` は環境変数を上書きする**（スクリプトが読み込む）。テストで環境変数を渡しても、リポジトリ直下に `.env.ps1` があると本物の SFTPGo・EPGStation に接続する。テストはスクリプトをスクラッチに複製して（`<tmp>/scripts/` に置けば `..\.env.ps1` が見つからない）、モックの HTTP サーバー（SFTPGo の `/api/v2/user/token` `dirs` `files`、EPGStation の `/api/recording`）に向ける。**`-DeleteAfterCopy` を本物に向けて試さない**
- 一時ファイルは Claude のスクラッチ用ディレクトリに置く。`COPY_RECORDINGS_DATA_DIR` をそこに向ければ、本番のログ・メトリクスを汚さない
- 管理者権限・実機のスリープが必要なものは、ここでは実行できない（`Install-Alloy.ps1` の導入、`Sleep-Computer.ps1` の実スリープ）。構文チェック（`[Management.Automation.Language.Parser]::ParseFile`）と `-WhatIf` までにして、実機の結果はユーザーに頼む
- Bash から長い PowerShell／Python を here-document で渡すと、引用符で壊れることがある。長いものはファイルに書いて実行する

## Windows PowerShell 5.1 の癖（すでに踏んだもの）
- `Invoke-RestMethod` は charset のない JSON を ISO-8859-1 として読む → `Invoke-WebRequest` + `RawContentStream` を UTF-8 で自分で復号
- `Invoke-WebRequest` の `.Content` は、`application/octet-stream` のとき `byte[]`（`SHA256SUMS` など拡張子のないファイル）
- `-OutFile` などは `[ ]` をワイルドカードとして扱う（録画名に含まれる）→ `-LiteralPath` と .NET の API
- `ConvertFrom-Json` の配列は `@(...)` で包むと入れ子になる
- `Invoke-WebRequest` は進捗表示で極端に遅い → `$ProgressPreference = 'SilentlyContinue'`
