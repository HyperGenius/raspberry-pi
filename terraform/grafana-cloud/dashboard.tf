# Grafana Cloud の Prometheus（スタックに最初からある。UID は直書きせず名前で参照する）
data "grafana_data_source" "prometheus" {
  name = coalesce(
    var.prometheus_data_source_name,
    "grafanacloud-${regex("^https://([a-z0-9-]+)\\.grafana\\.net", nonsensitive(var.grafana_url))[0]}-prom",
  )
}

# ダッシュボードとアラートルールを置くフォルダ
resource "grafana_folder" "raspberry_pi" {
  uid   = "raspberry-pi"
  title = "Raspberry Pi"
}

# パネルの id はアラートルールのリンク（__panelId__）にも使う
locals {
  dashboard_uid = "raspberry-pi"
  panel_ids = {
    undervoltage = 4
    cpu          = 5
    memory       = 6
    cpu_temp     = 7
    disk         = 8
    mount        = 11
    service      = 12
    container    = 13
  }
}

# JSON は dashboards/raspberry-pi.json.tftpl（${...} は Terraform が埋める。Grafana の変数は $instance の形で書く）
resource "grafana_dashboard" "raspberry_pi" {
  folder = grafana_folder.raspberry_pi.uid
  config_json = templatefile("${path.module}/dashboards/raspberry-pi.json.tftpl", {
    uid                     = local.dashboard_uid
    datasource_uid          = data.grafana_data_source.prometheus.uid
    job                     = var.job
    cpu_temp_celsius        = var.cpu_temp_celsius
    memory_used_percent_max = 100 - var.memory_available_percent
    disk_used_percent_max   = 100 - var.disk_free_percent
  })
}
