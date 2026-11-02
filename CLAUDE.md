# raspberry-pi

Raspberry Pi の IaC（Ansible: `roles/` `playbooks/` `inventories/`）、監視（`terraform/grafana-cloud`）、Windows PC 側のスクリプト（`scripts/` `windows/`）。使い方は README.md。階層ごとの注意は各ディレクトリの CLAUDE.md を見る。

- 作業は Windows と Mac に分かれる。Ansible・Terraform は Mac、`scripts/`・`windows/` は Windows で実装・検証してきた。両方にまたがる変更（メトリクス名など）は、片側だけで変えない
- `copy_recordings_*` のメトリクス名・ラベルは、`scripts/Copy-Recordings.ps1`（出力）と `terraform/grafana-cloud/alerts.tf` `dashboard.tf` `dashboards/`（利用）の契約。変えるときは両方を同じ PR で直す
- 秘密情報は Git に入れない: `.env.ps1`（Windows）、`vault.yml`（Ansible）、`*.tfvars`（Terraform）。例は `.env.ps1.example` `vault.yml.example` `terraform.tfvars.example`
- 改行は Git が LF に正規化する（`core.autocrlf=true`）。Windows の作業ツリーは CRLF になる。差分が全行に出たら、行末が混ざっている（`git diff --ignore-cr-at-eol` で確認）
- Issue → ブランチ（`feature/<番号>-<内容>`）→ PR の流れ。コミットメッセージは英語（README・Issue・PR 本文は日本語）
