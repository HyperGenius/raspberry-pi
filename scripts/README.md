# scripts/ 開発者向けメモ

利用者向けの手順（環境変数、タスクスケジューラの登録、Alloy の導入）はリポジトリ直下の README.md にある。ここは中身を変える人向け。

| ファイル | 役割 |
|---|---|
| `Copy-Recordings.ps1` | SFTPGo（REST API）から録画を PC へコピー（`-DeleteAfterCopy` で移動）。ログとメトリクスを書く |
| `Install-Alloy.ps1` | Grafana Alloy の導入と設定の配置（管理者権限） |
| `Sleep-Computer.ps1` | タスクに起こされた PC をスリープに戻す（`\MyTasks\SleepAfterCopy` タスクから起動） |
| `../windows/alloy/config.alloy.tmpl` | Alloy の設定のテンプレート |

## 全体の流れ

```
タスクスケジューラ \MyTasks\CopyRecordings (SYSTEM, 3:00, WakeToRun)
  └─ Copy-Recordings.ps1 -DeleteAfterCopy [-SleepAfter]
       ├─ <データ>\logs\copy-YYYYMMDD.log        ──┐
       ├─ <データ>\metrics\copy_recordings.prom  ──┼─ Alloy (サービス) ─→ Grafana Cloud (Loki / Prometheus)
       └─ (-SleepAfter) Start-ScheduledTask \MyTasks\SleepAfterCopy
              └─ Sleep-Computer.ps1: 復帰元の確認 → 120 秒待つ → スリープ
```

`<データ>` は `COPY_RECORDINGS_DATA_DIR`（既定 `%ProgramData%\CopyRecordings`）。ダッシュボード・アラートは `terraform/grafana-cloud`。

## Copy-Recordings.ps1

処理の順序: `.env.ps1` 読み込み → ログ・メトリクスのフォルダ準備 → 設定の確認 → EPGStation の録画確認 → 再帰コピー（必要なら 1 ファイルずつ削除）→ `Complete-Run`。

- **終了は `Complete-Run <reason> <code>` だけ。** メトリクスを書き、`-SleepAfter` ならスリープ用タスクを起動してから `exit` する。`reason` は `ok` / `recording` / `config` / `epgstation` / `auth` / `failed` / `delete_stopped`（`exit_reason` ラベルにそのまま出る）
- 終了コードは `ok` だけ 0。`recording`（録画中でコピーしなかった）も 1 にしている: タスクの再試行（`-RestartCount 3`、10 分おき）を動かすため
- `copy_recordings_last_success_timestamp_seconds` は、前回の `.prom` から正規表現で引き継ぐ（失敗や `recording` で 0 に戻さない）。「未実行」と「成功が続いていない」を別に判定できる
- `.prom` は一時ファイル（`.tmp`）に書いて `Move-Item -Force`。windows_exporter が書きかけを読まない。`.tmp` は textfile に拾われない
- ログの 1 行は `<ISO 8601 の時刻> <INFO|WARN|ERROR> <メッセージ>`。Alloy の `loki.process` が先頭を正規表現で読んで時刻とレベルを取り出す（形式を変えたら `config.alloy.tmpl` も直す）。改行は ` | ` に置き換えて 1 行にする
- ログが書けない（フォルダを作れない）ときは、コピーは続け、ログとメトリクスだけ諦める（警告を出す）。メトリクスはログが使えるときだけ書く
- `-WhatIf` ではログもメトリクスも書かない。スリープ用タスクも起動しない
- `-DeleteAfterCopy` は削除の直前に毎回 EPGStation を確認する。ここを緩めない（録画中のファイルを消す）

## Install-Alloy.ps1

- 手順: 管理者の確認 → `.env.ps1` → データ・`alloy` フォルダ作成（`icacls` で SYSTEM と Administrators のみ。SID 指定なので表示言語に依存しない）→ トークンと `config.alloy` を書く → 未導入ならダウンロード（`SHA256SUMS` で検証）してサイレントインストール → `alloy validate` → サービス再起動 → `127.0.0.1:12345/metrics` の `prometheus_remote_storage_samples_total` − `..._failed_total` が 0 より大きくなるまで最大 2 分待つ
- 何度実行してもよい。導入済み（サービス `Alloy` がある）なら、インストールは行わず、バージョンも変えない（上げるときは手でアンインストールしてから `-AlloyVersion` を付けて実行する）
- インストーラの引数: `/S` `/CONFIG="<path>"` `/DISABLEREPORTING=yes`。サービス名は `Alloy`、LocalSystem
- 送信確認で見ているのは Alloy 自身のメトリクス。`copy_recordings_*` が届くかは、`Copy-Recordings.ps1` を 1 回実行して約 1 分後に Explore で確かめる

## Sleep-Computer.ps1

- スリープを別タスクにしている理由: スリープすると、そのプロセスは次の復帰まで止まる。`Copy-Recordings.ps1` 自身がスリープすると、翌日 3:00 に前回のタスクが「実行中」のままで、新しい実行が始まらない
- スリープする条件: ①直近の復帰イベント（System ログ、`Microsoft-Windows-Power-Troubleshooter`、ID 1）が `-MaxWakeAgeHours`（8）以内で、メッセージに `NT TASK\MyTasks\CopyRecordings` を含む ②待ったあと、入力が `-MinIdleMinutes`（10）以内のセッションがない
- ①の判定は、復帰元の文言（`Timer - Windows will execute 'NT TASK\<タスクパス>' ...`）の英語部分に頼る。この PC では電源ボタンや Wi-Fi の復帰が「スリープしない」と判定されることまで確認済み。**タイマー復帰で「スリープする」側は未検証**（実機の最初の 3:00 の後に、ログの `sleep:` 行で確認する）
- ②は補助。コンソールセッションでは `WTSINFO.LastInputTime` が 0 で取れない（`no input`）ので、ブロックしない扱い。取れるのはリモートデスクトップなど
- `SetSuspendState(false, false, false)`（第 1 引数 false = スリープ。休止ではない）。`rundll32 powrprof.dll,SetSuspendState` は引数の癖で休止になることがあるので使わない
- 判定にはメディア再生などの検出を含まない
- `-WhatIf`: 待たず、スリープもしない（復帰元の確認までは実際に行う）

## 検証の方法（手元でできること）

- モックサーバー: SFTPGo の `GET /api/v2/user/token`（Basic 認証）、`/api/v2/user/dirs?path=`（`name`・`size`・`mode` の配列。ディレクトリは `mode` に 2147483648 のビット）、`/api/v2/user/files?path=`（本体）、EPGStation の `GET /api/recording`（`total`・`records`）を返す小さな HTTP サーバー。ポートを分けて「録画中」「接続不可」「認証エラー」を作る
- `copy_recordings_exit_reason` の 7 通りを、5.1 と 7 の両方で実行して `.prom` とログを見る
- Alloy: `windows/CLAUDE.md` の検証の手順
- 実機でしか確かめられないもの: Alloy の導入、タイマー復帰後のスリープ、SYSTEM としての `.env.ps1` の読み込み
