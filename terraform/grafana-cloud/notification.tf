# 通知文（Go テンプレート）。ホスト名・マウント先・現在の値はアラートルールの summary に入れる
locals {
  slack_title = <<-EOT
    {{ if eq .Status "firing" }}[FIRING:{{ len .Alerts.Firing }}]{{ else }}[RESOLVED]{{ end }} {{ .CommonLabels.alertname }}
  EOT

  # summary がないアラート（DatasourceError など）はアラート名と instance を出す
  slack_text = <<-EOT
    {{ range .Alerts }}{{ if eq .Status "firing" }}:rotating_light:{{ else }}:white_check_mark:{{ end }} {{ with .Annotations.summary }}{{ . }}{{ else }}{{ .Labels.alertname }} {{ .Labels.instance }}{{ end }}{{ with .DashboardURL }} <{{ . }}|ダッシュボード>{{ end }}
    {{ end }}
  EOT
}

resource "grafana_contact_point" "slack" {
  name = "Slack"

  slack {
    url   = var.slack_webhook_url
    title = trimspace(local.slack_title)
    text  = trimspace(local.slack_text)
  }
}

# 通知ポリシーはスタックに 1 つだけ。Terraform で管理するため、画面での変更は次の apply で上書きされる
resource "grafana_notification_policy" "root" {
  contact_point   = grafana_contact_point.slack.name
  group_by        = ["grafana_folder", "alertname"]
  group_wait      = "30s"
  group_interval  = "5m"
  repeat_interval = var.repeat_interval
}
