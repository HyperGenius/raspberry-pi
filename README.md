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
│       │   └── raspberry_pi/
│       │       ├── main.yml
│       │       ├── vault.yml     # 秘密情報（ansible-vault で暗号化、Git 管理外）
│       │       └── vault.yml.example
│       └── host_vars/        # ホスト固有の変数（1台 = 1ファイル）
│           ├── rpi-01.yml
│           └── rpi-02.yml
├── playbooks/
│   ├── site.yml              # エントリポイント
│   └── prepare_sd.yml        # 初回起動前に Mac 上で bootfs を準備する
└── roles/
    ├── bootfs/               # bootfs の user-data / network-config / meta-data / cmdline.txt
    └── common/               # 全台共通の初期設定
```

## SD カードを準備する（初回起動前）

ブートパーティション（bootfs）のファイルは `playbooks/prepare_sd.yml` で生成・修正する。手で編集しない。

| ファイル | 扱い |
|---|---|
| `cmdline.txt` | `resize` を取り除くだけ（`root=PARTUUID=...` はイメージごとに異なるため丸ごとは管理しない） |
| `user-data` | inventory から生成（hostname・ユーザー・SSH 公開鍵・root の自動拡張の無効化） |
| `network-config` | inventory から生成（wlan0 / eth0 とも DHCP） |
| `meta-data` | inventory から生成（`instance-id`） |

1. 初回のみ: 秘密情報を ansible-vault で作成する（項目は `vault.yml.example` を参照）。`vault.yml` は `.gitignore` 済みで、リポジトリには含めない
   ```sh
   openssl passwd -6   # ログインパスワードのハッシュを生成
   ansible-vault create inventories/home/group_vars/raspberry_pi/vault.yml
   ```
2. Raspberry Pi Imager で OS イメージを書き込む（OS カスタマイズは使わない）
3. Mac にマウントされた bootfs に対して実行する
   ```sh
   ansible-playbook playbooks/prepare_sd.yml -e target=rpi-01 --ask-vault-pass
   # bootfs のマウント先が異なる場合: -e bootfs_path=/Volumes/xxx

   # 必ず取り出してから抜く（書き込みが反映されず、起動時に
   # "Unable to read partition as FAT" で止まることがある）。
   # ターミナルのカレントディレクトリが /Volumes/bootfs だと取り出せない
   cd ~ && diskutil eject /Volumes/bootfs
   ```
4. SD カードを取り出して Pi を起動する。初回は DHCP なので mDNS 名で接続する
   ```sh
   # ホスト鍵は IP ではなくホスト名（HostKeyAlias）で known_hosts に記録する。
   # Ansible は確認プロンプトに答えられないので、初回だけ手で接続して登録する
   ssh-keygen -R rpi-01   # SD カードを作り直した場合は古い鍵を消す
   ssh -o HostKeyAlias=rpi-01 -i ~/.ssh/id_ed25519_rp4 genius@rpi-01.local true

   ansible-playbook playbooks/site.yml --limit rpi-01 -e ansible_host=rpi-01.local
   ```

cloud-init が動くのは初回起動の 1 回だけ（`instance-id` で判定）。起動後に bootfs を編集しても反映されないため、bootfs には SSH で接続できるまでに必要な最小限だけを入れ、それ以外は role で設定する。

## Raspberry Pi を追加する

1. `inventories/home/hosts.yml` にホストを追加
2. `inventories/home/host_vars/<hostname>.yml` を作成
3. 上記「SD カードを準備する」の手順で SD カードを作成
4. 用途別の設定が必要なら `roles/<role>/` を作り、グループと playbook に紐づける

## 使い方

```sh
ansible-galaxy collection install -r requirements.yml

# 全台
ansible-playbook playbooks/site.yml

# 特定のホストだけ
ansible-playbook playbooks/site.yml --limit rpi-01
```
