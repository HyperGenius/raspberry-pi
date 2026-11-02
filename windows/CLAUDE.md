# windows/（Windows PC 側の設定ファイル）

`windows/alloy/config.alloy.tmpl` は `scripts/Install-Alloy.ps1` が `@@NAME@@` を置き換えて `%ProgramData%\CopyRecordings\alloy\config.alloy` に配置する。Pi 側の Alloy の設定は `roles/alloy/templates/config.alloy.j2`（別物）。

- Alloy の文字列では `\` がエスケープなので、パスは `/` で書く（`Install-Alloy.ps1` が置き換え時に変換する）。置き換える値に `"` `\` 改行があれば `Install-Alloy.ps1` が拒否する
- textfile コレクタは `prometheus.exporter.windows` の `enabled_collectors = ["textfile"]` と `textfile { directories = [...] }`（`text_file_directory` は非推奨）。`.prom` は `.prom` 拡張子で、末尾に改行が必要（`Copy-Recordings.ps1` は一時ファイルに書いてリネームする）
- 設定を変えたら、公式の Windows 版バイナリで検証する: `alloy-windows-amd64.exe.zip`（GitHub のリリース）を展開し、`@@..@@` を適当な値に置き換えた設定に `alloy-windows-amd64.exe validate <file>`。ローカルの Alloy を `run` して、Loki 互換のモックにログが届くところまで確かめられる（Prometheus 側は 60 秒間隔のスクレイプを待つ）
- 送信先・トークンはコミットしない（`.env.ps1` の `GRAFANA_CLOUD_*`）。トークンは `metrics:write` と `logs:write` だけ
