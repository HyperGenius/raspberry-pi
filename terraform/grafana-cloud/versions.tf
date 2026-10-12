terraform {
  # Terraform・プロバイダのバージョンを固定する（上げるときは .terraform.lock.hcl も更新してコミットする）
  required_version = "~> 1.14.0"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "4.49.0"
    }
  }

  # state はローカル（terraform.tfstate）に置く。Webhook URL などの秘密情報を含むため Git 管理外（.gitignore）
}

provider "grafana" {
  url  = var.grafana_url
  auth = var.grafana_auth
}
