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
│       │       └── main.yml
│       ├── vault.yml         # 秘密情報（ansible-vault で暗号化、Git 管理外。prepare_sd.yml だけが読み込む）
│       ├── vault.yml.example
│       └── host_vars/        # ホスト固有の変数（1台 = 1ファイル）
│           ├── rpi-01.yml
│           └── rpi-02.yml
├── playbooks/
│   ├── site.yml              # エントリポイント
│   └── prepare_sd.yml        # 初回起動前に Mac 上で bootfs を準備する
└── roles/
    ├── bootfs/               # bootfs の user-data / network-config / meta-data / cmdline.txt
    ├── static_ip/            # 固定IP
    ├── sd_partition/         # SD カードのパーティション構成（root の拡張と Docker 用領域）
    ├── usb_storage/          # 既存の USB ストレージの自動マウント
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
   ansible-vault create inventories/home/vault.yml
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
4. SD カードを取り出して Pi を起動する。初回は DHCP なので mDNS 名（`<hostname>.local`、hostname は host_vars の値）で接続する
   ```sh
   # ホスト鍵は IP ではなくホスト名（HostKeyAlias）で known_hosts に記録する。
   # Ansible は確認プロンプトに答えられないので、初回だけ手で接続して登録する
   ssh-keygen -R rpi-01   # SD カードを作り直した場合は古い鍵を消す
   ssh -o HostKeyAlias=rpi-01 -i ~/.ssh/id_ed25519_rp4 genius@raspberrypi.local true

   # ansible_host（固定IP）に接続できなければ、自動で bootstrap_host（<hostname>.local）に接続する。
   # -e ansible_host=... は固定IP化後の接続先の切り替えを妨げるので使わない
   ansible-playbook playbooks/site.yml --limit rpi-01
   ```

cloud-init が動くのは初回起動の 1 回だけ（`instance-id` で判定）。起動後に bootfs を編集しても反映されないため、bootfs には SSH で接続できるまでに必要な最小限だけを入れ、それ以外は role で設定する。

## 固定IP（roles/static_ip）

`host_vars/<host>.yml` の `static_ip_interfaces` に書いたインターフェースを固定IPにする。`hosts.yml` の `ansible_host` は、接続に使うインターフェース（`static_ip_connect_interface`、既定は wlan0）の固定IPにしておく。

```yaml
static_ip_interfaces:
  - ifname: wlan0
    address: 192.168.10.55/24
    gateway: 192.168.10.1
    dns: [192.168.10.1]
```

- cloud-init（netplan）が作った接続プロファイルをそのまま変更する。変更は NetworkManager が `/etc/netplan/90-NM-<UUID>.yaml` に書き戻す
- 変更前に NetworkManager の checkpoint を作り、新しいアドレスへの再接続とゲートウェイへの ping が確認できたら確定する。確認できなければ元に戻す（接続が切れた場合は `static_ip_rollback_timeout` 秒後に NetworkManager が自動で戻す）
- `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` を置き、cloud-init がネットワーク設定を作り直さないようにする
- 実機専用のため `hardware` タグを付けている（Molecule では `--skip-tags hardware` で除外する）。単独で実行する場合は `--tags static_ip`
- 開発中はモニタとキーボードをつなぎ、ロールバックに失敗した場合に備える

## パーティション構成（roles/sd_partition）

初回起動時の root の自動拡張を無効にしているため、root（p2）はイメージ由来の最小サイズで起動する。この role で p2 を指定サイズまで拡張し、残りを Docker 用（p3）にする。

| パーティション | サイズ | FS | ラベル | マウント先 |
|---|---|---|---|---|
| p1 | Imager の初期値（変更しない） | vfat | bootfs | `/boot/firmware` |
| p2 | `sd_partition_root_size`（既定 `14GiB`） | ext4 | rootfs | `/` |
| p3 | 残り全部 | ext4 | `docker` | `/var/lib/docker`（`defaults,noatime`、fstab に登録） |

- 実行前に次を確認し、満たさなければ何も変更せずに失敗する
  - `/boot/firmware/cmdline.txt` に `resize` が含まれていない
  - パーティションテーブルが MBR（msdos）で、p2 が `/` にマウントされている
  - p2 の後ろに空き領域がある、または p3 が既にある（ない場合は初回起動時に root が自動拡張されたとみなす。SD カードを作り直す）
  - `/var/lib/docker` が空、または既に p3 がマウントされている
- p2 は現在のサイズが指定サイズより小さいときだけ拡張する（縮小はしない）。マウント中のパーティションは `parted -s` では変更できないため、`sfdisk -N 2` で開始位置を変えずにサイズだけ書き換え、`partx` でカーネルに伝えてから `resize2fs` でオンライン拡張する
- p3 のフォーマットは、ファイルシステムがない場合だけ行う（`force` は使わない）
- 新しいパーティションがカーネルに反映されない場合は、1回だけ再起動する
- `--check` では、パーティションテーブルを変更する場合は予定（p2 のサイズと p3 の作成）を表示してそこで止まる
- 実機専用のため `hardware` タグを付けている。単独で実行する場合は `--tags sd_partition`。Docker の導入より前に実行すること

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags sd_partition --check   # 予定を確認
ansible-playbook playbooks/site.yml --limit rpi-01 --tags sd_partition
```

## USB ストレージ（roles/usb_storage）

大きなファイルは既存の外付け USB メモリに置く。既存のデータをそのまま使い、自動マウントの設定（fstab への登録とマウント）だけを行う。**mkfs と chown は行わない。**

`host_vars/<host>.yml` の `usb_storage_devices` に書く（UUID は `lsblk -f` で確認する）。

```yaml
usb_storage_devices:
  - uuid: 96efbf0e-c2e7-4007-b81d-1177c5f73fdc
    fstype: ext4
    path: /mnt/data
  - uuid: 226667176666EACD
    fstype: ntfs
    path: /mnt/share
```

| FS | マウントオプション |
|---|---|
| ext4 | `defaults,noatime`（`usb_storage_ext4_opts`）、passno 2 |
| NTFS | `defaults,noatime` + `uid` / `gid` / `umask`（`usb_storage_ntfs_uid` / `_gid` / `_umask`、既定 `1000` / `1000` / `022`）、passno 0 |

- `UUID=...` でマウントする（`/dev/sdX` の順番には依存しない）
- 全デバイスに `nofail,x-systemd.device-timeout=10s` を付け、USB が未接続でも起動が止まらないようにする
- NTFS はカーネル内蔵の `ntfs3` を使う。使えない場合は `ntfs-3g` をインストールして使う
- 実行前に、UUID のデバイスが接続されていること・ファイルシステムが `fstype` と一致することを確認する（満たさなければ何も変更せずに失敗する）
- デスクトップ（udisks2）が `/media/<user>/...` に自動マウントしている場合は、アンマウントしてから指定のパスにマウントする
- `nofail` によりマウントの失敗に起動時には気づけないため、最後に指定のパスに読み書き可能でマウントされていることを確認し、されていなければ失敗させる。NTFS は dirty フラグ（Windows で安全に取り外さなかった、高速スタートアップなど）が立っていると、マウントに失敗したり読み取り専用になったりする。その場合は Windows で `chkdsk /f` を実行するか、`sudo ntfsfix -d /dev/sdX1` を実行してから再実行する
- `usb_storage_write_user`（既定は `ansible_user`）で書き込めることを確認する。NTFS で書き込めなければ失敗させ、ext4 では `[要確認]` を表示するだけにする
- 単独で実行する場合は `--tags usb_storage`

運用規約:

- NTFS（`/mnt/share`）は Docker の bind mount 先に使用しない（Linux の所有者・パーミッションを保持できないため）
- ext4（`/mnt/data`）の既存ファイルの UID が Pi 上のユーザーと一致しない場合（`[要確認]` が表示される）は、所有者を変更するかどうかを手作業で判断する。role では chown しない

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags usb_storage
```

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
