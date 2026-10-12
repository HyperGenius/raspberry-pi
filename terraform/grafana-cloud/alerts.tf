# アラートルール。各ルールは A（Prometheus の instant クエリ。現在の値）と B（A のしきい値）で判定する。
# summary にホスト名・マウント先・現在の値（$values.A）を入れ、Slack の通知文に出す（notification.tf）
locals {
  selector = "job=\"${var.job}\""

  # 停止を検知するホストごとの absent_over_time（届いていなければ instance ラベル付きで 1 を返す）
  no_metrics_expr = join(" or ", [
    for i in var.instances :
    "absent_over_time(node_uname_info{${local.selector},instance=\"${i}\"}[${var.no_metrics_for}])"
  ])

  # マウントされているべきマウント先ごとの absent_over_time（届いていなければ instance・mountpoint ラベル付きで 1 を返す）。
  # node_uname_info が同じ期間に届いているホストだけにする。どちらも同じ scrape のサンプルなので、Pi 全体が止まると
  # 両方が同時に期間から外れ、「メトリクスが届かない」と重複して発火しない
  mount_missing_expr = join(" or ", flatten([
    for i, mounts in var.mount_points : [
      for m in mounts :
      "(absent_over_time(node_filesystem_size_bytes{${local.selector},instance=\"${i}\",mountpoint=\"${m}\"}[${var.mount_missing_for}]) and on (instance) count_over_time(node_uname_info{${local.selector},instance=\"${i}\"}[${var.mount_missing_for}]))"
    ]
  ]))

  # unit が active のコンテナだけを見る（unit が止まっているときは「サービスの停止」で通知し、起動中は待つ）
  container_down_expr = "compose_container_up{${local.selector}} and on (instance, unit) label_replace(node_systemd_unit_state{${local.selector},state=\"active\"} == 1, \"unit\", \"$1\", \"name\", \"(.+)\")"

  # compose-metrics.timer が書き出すファイルが更新されていない秒数（または textfile の読み込みの失敗）。
  # Pi が止まったときに「メトリクスが届かない」と重複しないよう、最新の値は 2 分以内のものだけを使う
  # （その間の秒数は 2 分 + timer の間隔までなので、container_metrics_stale_for は 4 分以上にする）
  container_metrics_stale_seconds = tonumber(regex("^[0-9]+", var.container_metrics_stale_for)) * (endswith(var.container_metrics_stale_for, "h") ? 3600 : 60)
  container_metrics_stale_expr    = "(time() - max by (instance) (max_over_time(node_textfile_mtime_seconds{${local.selector}}[2m]))) > ${local.container_metrics_stale_seconds} or max by (instance) (node_textfile_scrape_error{${local.selector}})"

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
    {
      name      = "マウントされていない"
      expr      = local.mount_missing_expr
      evaluator = "gt"
      threshold = 0
      for       = "0s"
      panel     = "mount"
      summary   = "{{ $labels.instance }} の {{ $labels.mountpoint }} がマウントされていない（${var.mount_missing_for} 以上。USB の切断など。dmesg・findmnt を確認する）"
    },
    {
      # ext4 は I/O エラーで読み取り専用に切り替わる（USB が切断される直前など）
      name      = "読み取り専用のマウント"
      expr      = "node_filesystem_readonly{${local.selector}}"
      evaluator = "gt"
      threshold = 0
      for       = var.readonly_for
      panel     = "mount"
      summary   = "{{ $labels.instance }} の {{ $labels.mountpoint }} が読み取り専用になっている（I/O エラーの可能性。dmesg を確認する）"
    },
    {
      # roles/alloy の alloy_compose_units（sftpgo.service など）。USB のアンマウントでも止まる（RequiresMountsFor）
      name      = "サービスの停止"
      expr      = "node_systemd_unit_state{${local.selector},state=~\"inactive|failed\"}"
      evaluator = "gt"
      threshold = 0
      for       = var.service_down_for
      panel     = "service"
      summary   = "{{ $labels.instance }} の {{ $labels.name }} が {{ $labels.state }} になっている（${var.service_down_for} 以上）"
    },
    {
      name      = "コンテナの停止"
      expr      = local.container_down_expr
      evaluator = "lt"
      threshold = 1
      for       = var.container_down_for
      panel     = "container"
      summary   = "{{ $labels.instance }} のコンテナ {{ $labels.container }}（{{ $labels.unit }}）が動いていない（${var.container_down_for} 以上）"
    },
    {
      name      = "コンテナの異常"
      expr      = "compose_container_unhealthy{${local.selector}}"
      evaluator = "gt"
      threshold = 0
      for       = var.container_unhealthy_for
      panel     = "container"
      summary   = "{{ $labels.instance }} のコンテナ {{ $labels.container }}（{{ $labels.unit }}）のヘルスチェックが unhealthy（${var.container_unhealthy_for} 以上）"
    },
    {
      # 再起動の回数（RestartCount）が変わった回数。scrape の間に複数回再起動すると 1 回と数える
      name      = "コンテナの再起動の繰り返し"
      expr      = "changes(compose_container_restart_count{${local.selector}}[${var.container_restarts_window}])"
      evaluator = "gt"
      threshold = var.container_restarts
      for       = "0s"
      panel     = "container"
      summary   = "{{ $labels.instance }} のコンテナ {{ $labels.container }}（{{ $labels.unit }}）が ${var.container_restarts_window} に {{ printf \"%.0f\" $values.A.Value }} 回再起動した（しきい値: ${var.container_restarts} 回超）"
    },
    {
      name      = "コンテナの状態を取得できない"
      expr      = local.container_metrics_stale_expr
      evaluator = "gt"
      threshold = 0
      for       = "0s"
      panel     = "container"
      summary   = "{{ $labels.instance }} のコンテナの状態が更新されていない（journalctl -u compose-metrics.service を確認する）"
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
