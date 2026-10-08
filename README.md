# raspberry-pi

Raspberry Pi のプロビジョニング用 IaC（Ansible）。

## 構成

```
.
├── ansible.cfg               # Ansible 設定（デフォルト inventory など）
├── requirements.yml          # 依存コレクション
├── inventories/
│   └── home/                 # 環境ごとの inventory（拠点が増えたら並べて追加）
│       ├── hosts.yml         # ホスト一覧とグループ
│       ├── group_vars/       # グループ共通の変数
│       │   ├── all.yml
│       │   └── raspberry_pi.yml
│       └── host_vars/        # ホスト固有の変数（1台 = 1ファイル）
│           ├── rpi-01.yml
│           └── rpi-02.yml
├── playbooks/
│   └── site.yml              # エントリポイント
└── roles/
    └── common/               # 全台共通の初期設定
```

## Raspberry Pi を追加する

1. `inventories/home/hosts.yml` にホストを追加
2. `inventories/home/host_vars/<hostname>.yml` を作成
3. 用途別の設定が必要なら `roles/<role>/` を作り、グループと playbook に紐づける

## 使い方

```sh
ansible-galaxy collection install -r requirements.yml

# 全台
ansible-playbook playbooks/site.yml

# 特定のホストだけ
ansible-playbook playbooks/site.yml --limit rpi-01
```
