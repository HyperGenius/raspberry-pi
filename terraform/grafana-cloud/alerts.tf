# アラートルール。各ルールは A（Prometheus の instant クエリ。現在の値）と B（A のしきい値）で判定する。
# summary にホスト名・マウント先・現在の値（$values.A）を入れ、Slack の通知文に出す（notification.tf）
locals {
  selector = "job=\"${var.job}\""

  # 停止を検知するホストごとの absent_over_time（届いていなければ instance ラベル付きで 1 を返す）
  no_metrics_expr = join(" or ", [
    for i in var.instances :
    "absent_over_time(node_uname_info{${local.selector},instance=\"${i}\"}[${var.no_metrics_for}])"
  ])

  rules = [
    {
      name      = "空き容量の不足"
      expr      = "100 * node_filesystem_avail_bytes{${local.selector}} / node_filesystem_size_bytes{${local.selector}}"
      evaluator = "lt"
      threshold = var.disk_free_percent
      for       = var.disk_free_for
      panel     = "disk"
      summary   = "{{ $labels.instance }} の {{ $labels.mountpoint }} の空き容量: {{ printf \"%.1f\" $values.A.Value }}%（しきい値: ${var.disk_free_percent}% 未満）"
    },
    {
      name      = "CPU の高温"
      expr      = "node_thermal_zone_temp{${local.selector},type=\"cpu-thermal\"}"
      evaluator = "gt"
      threshold = var.cpu_temp_celsius
      for       = var.cpu_temp_for
      panel     = "cpu_temp"
      summary   = "{{ $labels.instance }} の CPU の温度: {{ printf \"%.1f\" $values.A.Value }}℃（しきい値: ${var.cpu_temp_celsius}℃ 超が ${var.cpu_temp_for}）"
    },
    {
      name      = "メモリの不足"
      expr      = "100 * node_memory_MemAvailable_bytes{${local.selector}} / node_memory_MemTotal_bytes{${local.selector}}"
      evaluator = "lt"
      threshold = var.memory_available_percent
      for       = var.memory_available_for
      panel     = "memory"
      summary   = "{{ $labels.instance }} の使えるメモリ: {{ printf \"%.1f\" $values.A.Value }}%（しきい値: ${var.memory_available_percent}% 未満が ${var.memory_available_for}）"
    },
    {
      name      = "メトリクスが届かない"
      expr      = local.no_metrics_expr
      evaluator = "gt"
      threshold = 0
      for       = "0s"
      panel     = "cpu"
      summary   = "{{ $labels.instance }} のメトリクスが ${var.no_metrics_for} 届いていない（Pi の停止・ネットワーク断・Alloy の停止）"
    },
    {
      # rpi_volt（hwmon）の低電圧の警告。1 で低電圧（電源の容量不足でスロットリングされる）
      name      = "低電圧"
      expr      = "node_hwmon_in_lcrit_alarm_volts{${local.selector},chip=\"soc:firmware_raspberrypi_hwmon\"}"
      evaluator = "gt"
      threshold = 0
      for       = var.undervoltage_for
      panel     = "undervoltage"
      summary   = "{{ $labels.instance }} で低電圧を検知した（電源・ケーブルを確認する）"
    },
  ]
}

resource "grafana_rule_group" "raspberry_pi" {
  name             = "Raspberry Pi"
  folder_uid       = grafana_folder.raspberry_pi.uid
  interval_seconds = 60 # roles/alloy の alloy_scrape_interval に合わせる

  dynamic "rule" {
    for_each = local.rules

    content {
      name      = rule.value.name
      condition = "B"
      for       = rule.value.for

      # 届かないことは「メトリクスが届かない」で通知するため、ほかのルールではデータがなくても通知しない
      no_data_state  = "OK"
      exec_err_state = "Error"

      annotations = {
        summary          = rule.value.summary
        __dashboardUid__ = grafana_dashboard.raspberry_pi.uid
        __panelId__      = tostring(local.panel_ids[rule.value.panel])
      }

      data {
        ref_id         = "A"
        datasource_uid = data.grafana_data_source.prometheus.uid

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode({
          refId   = "A"
          expr    = rule.value.expr
          instant = true
          range   = false
        })
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId      = "B"
          type       = "threshold"
          expression = "A"
          datasource = { type = "__expr__", uid = "__expr__" }
          conditions = [{
            evaluator = { type = rule.value.evaluator, params = [rule.value.threshold] }
          }]
        })
      }
    }
  }
}
