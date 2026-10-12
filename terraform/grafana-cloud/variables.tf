# ---- 認証・秘密情報（terraform.tfvars か TF_VAR_* で渡す。値は Git に含めない）----
variable "grafana_url" {
  description = "Grafana Cloud のスタックの URL（https://<stack>.grafana.net）"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^https://[a-z0-9-]+\\.grafana\\.net/?$", var.grafana_url))
    error_message = "grafana_url は https://<stack>.grafana.net にすること。"
  }
}

variable "grafana_auth" {
  description = "スタックのサービスアカウントのトークン（Terraform 専用。Alloy のトークンとは分ける）"
  type        = string
  sensitive   = true
}

variable "slack_webhook_url" {
  description = "通知を送る Slack チャンネルの Incoming Webhook の URL"
  type        = string
  sensitive   = true

  validation {
    condition     = startswith(var.slack_webhook_url, "https://hooks.slack.com/")
    error_message = "slack_webhook_url は Slack の Incoming Webhook の URL（https://hooks.slack.com/...）にすること。"
  }
}

# ---- メトリクス ----
variable "prometheus_data_source_name" {
  description = "Grafana Cloud の Prometheus のデータソース名。null ならスタックの URL から grafanacloud-<stack>-prom とする"
  type        = string
  default     = null
}

variable "job" {
  description = "メトリクスの job ラベル（roles/alloy の alloy_job）"
  type        = string
  default     = "integrations/node_exporter"
}

variable "instances" {
  description = "メトリクスが届かないことを検知するホスト（instance ラベル。roles/alloy を適用したホスト）"
  type        = list(string)
  default     = ["rpi-01"]

  validation {
    condition     = length(var.instances) > 0 && alltrue([for i in var.instances : can(regex("^[A-Za-z0-9._-]+$", i))])
    error_message = "instances は英数字・.・_・- のホスト名を 1 つ以上にすること。"
  }
}

# ---- 通知 ----
variable "repeat_interval" {
  description = "同じアラートを繰り返し通知する間隔"
  type        = string
  default     = "4h"

  validation {
    condition     = can(regex("^[0-9]+[smhdw]$", var.repeat_interval))
    error_message = "repeat_interval は数字 + s / m / h / d / w にすること（例: 4h）。"
  }
}

# ---- アラートのしきい値・継続時間（継続時間は数字 + s / m / h）----
variable "disk_free_percent" {
  description = "空き容量（%）がこの値を下回ったら通知する"
  type        = number
  default     = 10

  validation {
    condition     = var.disk_free_percent > 0 && var.disk_free_percent < 100
    error_message = "disk_free_percent は 0 より大きく 100 より小さくすること。"
  }
}

variable "disk_free_for" {
  description = "空き容量がしきい値を下回った状態がこの時間続いたら通知する"
  type        = string
  default     = "5m"

  validation {
    condition     = can(regex("^[0-9]+[smh]$", var.disk_free_for))
    error_message = "disk_free_for は数字 + s / m / h にすること（例: 5m）。"
  }
}

variable "cpu_temp_celsius" {
  description = "CPU の温度（℃）がこの値を超えたら通知する"
  type        = number
  default     = 75
}

variable "cpu_temp_for" {
  description = "CPU の温度がしきい値を超えた状態がこの時間続いたら通知する"
  type        = string
  default     = "5m"

  validation {
    condition     = can(regex("^[0-9]+[smh]$", var.cpu_temp_for))
    error_message = "cpu_temp_for は数字 + s / m / h にすること（例: 5m）。"
  }
}

variable "memory_available_percent" {
  description = "使えるメモリ（MemAvailable / MemTotal、%）がこの値を下回ったら通知する"
  type        = number
  default     = 10

  validation {
    condition     = var.memory_available_percent > 0 && var.memory_available_percent < 100
    error_message = "memory_available_percent は 0 より大きく 100 より小さくすること。"
  }
}

variable "memory_available_for" {
  description = "使えるメモリがしきい値を下回った状態がこの時間続いたら通知する"
  type        = string
  default     = "5m"

  validation {
    condition     = can(regex("^[0-9]+[smh]$", var.memory_available_for))
    error_message = "memory_available_for は数字 + s / m / h にすること（例: 5m）。"
  }
}

variable "no_metrics_for" {
  description = "メトリクスがこの時間届かなかったら通知する（Pi の停止・ネットワーク断・Alloy の停止）"
  type        = string
  default     = "10m"

  validation {
    condition     = can(regex("^[0-9]+[smh]$", var.no_metrics_for))
    error_message = "no_metrics_for は数字 + s / m / h にすること（例: 5m）。"
  }
}

variable "undervoltage_for" {
  description = "低電圧の警告がこの時間続いたら通知する（0s なら 1 回でも検知したら通知する）"
  type        = string
  default     = "0s"

  validation {
    condition     = can(regex("^[0-9]+[smh]$", var.undervoltage_for))
    error_message = "undervoltage_for は数字 + s / m / h にすること（例: 5m）。"
  }
}
