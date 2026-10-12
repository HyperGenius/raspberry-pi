# raspberry-pi

Raspberry Pi のプロビジョニング用 IaC（Ansible）と、監視（Grafana Cloud）の設定（Terraform）。

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
│       ├── vault.yml         # 秘密情報（ansible-vault で暗号化、Git 管理外。prepare_sd.yml と site.yml の sftpgo・epgstation・alloy だけが読み込む）
│       ├── vault.yml.example
│       └── host_vars/        # ホスト固有の変数（1台 = 1ファイル）
│           ├── rpi-01.yml
│           └── rpi-02.yml
├── playbooks/
│   ├── site.yml              # エントリポイント
│   └── prepare_sd.yml        # 初回起動前に Mac 上で bootfs を準備する
├── roles/
│   ├── bootfs/               # bootfs の user-data / network-config / meta-data / cmdline.txt
│   ├── static_ip/            # 固定IP
│   ├── sd_partition/         # SD カードのパーティション構成（root の拡張と Docker 用領域）
│   ├── sd_longevity/         # SD カードの延命（swap を zram のみに、journald の揮発化、root の noatime）
│   ├── usb_storage/          # 既存の USB ストレージの自動マウント
│   ├── docker/               # Docker（データは SD カードの p3、ログのローテーション）
│   ├── sftpgo/               # SFTPGo で USB のディレクトリを LAN に公開する（REST API / WebDAV / Web クライアント）
│   ├── epgstation/           # Mirakurun + EPGStation でテレビ番組を録画する（PX-S1UD、ハードウェアエンコード）
│   ├── plex/                 # Plex Media Server で USB のディレクトリを LAN に配信する
│   ├── alloy/                # Grafana Alloy でメトリクス（容量・温度・CPU・メモリ）を Grafana Cloud に送る
│   └── common/               # 全台共通の初期設定
└── terraform/
    └── grafana-cloud/        # Grafana Cloud のダッシュボード・アラート・Slack への通知（Terraform）
        ├── versions.tf       # Terraform・Grafana プロバイダのバージョン（.terraform.lock.hcl もコミットする）
        ├── variables.tf      # 認証・秘密情報・アラートのしきい値と継続時間
        ├── terraform.tfvars.example
        ├── dashboard.tf      # フォルダ・ダッシュボード・データソースの参照
        ├── dashboards/
        │   └── raspberry-pi.json.tftpl
        ├── notification.tf   # Slack の通知先・通知ポリシー
        └── alerts.tf         # アラートルール
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

## SD カードの延命（roles/sd_longevity）

SD カードへの書き込みを減らす。実行するタイミングは任意。

| 対象 | 設定 | ファイル |
|---|---|---|
| swap | zram（RAM 上）だけにする。SD 上の swap ファイル（`/var/swap`）は使わない | `/etc/rpi/swap.conf.d/90-sd-longevity.conf`（`Mechanism=zram`） |
| journald | `Storage=volatile`（`/run/log/journal` にだけ書く）、`RuntimeMaxUse` で上限を決める | `/etc/systemd/journald.conf.d/90-sd-longevity.conf` |
| root | マウントオプションに `noatime` を付ける | `/etc/fstab` |

| 変数 | 既定 | 内容 |
|---|---|---|
| `sd_longevity_journald_runtime_max_use` | `50M` | journald のログ（RAM 上）の上限。超えると古いものから消える |
| `sd_longevity_swap_file` | `/var/swap` | rpi-swap の swap ファイル（`swap.conf` の `File::Path` と同じにする） |

- Trixie の swap は rpi-swap（systemd の generator）が管理する。既定の `Mechanism=auto` は zram+file で、**SD 上の `/var/swap` を zram の writeback 先（使われていないページの書き出し先）に使う**。`Mechanism=zram` にすると、rpi-swap が起動時に `/var/swap` を削除する
- 古い swap ファイル（`dphys-swapfile`）が残っていれば削除する
- swap の設定は起動時に反映されるため、swap が zram だけになっていなければ 1 回だけ再起動する
- 実行前に、rpi-swap 以外の swap（fstab の swap エントリなど）がないことを確認する（あれば何も変更せずに失敗する）
- journald は Raspberry Pi OS 同梱の設定（`/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`）でも揮発化されているが、上限を変えるため role でも置く。変更したら journald を再起動する（ログは消えない。OS を再起動すると消える）
- root の `noatime` は fstab に書き、現在のマウントにも remount で反映する（`relatime` などの atime 系オプションは外す）
- 最後に、有効な swap が zram だけで writeback 先がないこと、journald が `/var/log/journal` のファイルを開いていないこと、`/` が `noatime` でマウントされていることを確認する
- 再起動を伴うため実機専用（`hardware` タグ）。単独で実行する場合は `--tags sd_longevity`

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags sd_longevity --check   # 予定を確認
ansible-playbook playbooks/site.yml --limit rpi-01 --tags sd_longevity
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

## Docker（roles/docker）

Docker 公式の apt リポジトリ（`download.docker.com/linux/debian`）から Docker Engine と compose / buildx プラグインをインストールする。データは `/var/lib/docker`（SD カードの p3、`roles/sd_partition`）に置く。

- 実行前に `/var/lib/docker` に `docker_data_device`（既定 `/dev/mmcblk0p3`、ext4）がマウントされていることを確認し、されていなければ何も変更せずに失敗する。`sd_partition` role の後に実行すること
- `/etc/systemd/system/docker.service.d/10-mounts.conf` に `RequiresMountsFor=/var/lib/docker` を置き、起動時に p3 のマウントが完了してから dockerd を起動する
- `/etc/docker/daemon.json` でコンテナのログ（json-file）をローテーションする。変更すると Docker を再起動する（実行中のコンテナも再起動される）。ログ設定はコンテナの作成時に決まるため、既存のコンテナには作り直すまで反映されない

| 変数 | 既定 | 内容 |
|---|---|---|
| `docker_log_max_size` | `10m` | ログファイル1つの最大サイズ |
| `docker_log_max_file` | `3` | 残すログファイルの数 |
| `docker_containerd_snapshotter` | `false` | containerd の image store を使うか |

- Docker 29 以降の新規インストールでは containerd の image store が既定になり、イメージが `/var/lib/containerd`（root パーティション）に置かれる。`docker_containerd_snapshotter: false` でこれを無効にし、イメージも `/var/lib/docker`（p3、storage driver は overlay2）に置く。切り替えると、切り替える前に pull したイメージは見えなくなる
- 最後に `docker info` の Docker Root Dir が `/var/lib/docker` で、その実体が p3 であることを確認する
- `--check` では、Docker が未インストールの場合はインストールの予定を表示してそこで止まる
- 単独で実行する場合は `--tags docker`

運用規約:

- 大きなファイルの bind mount 先は `/mnt/data`（USB の ext4）に限定する。p3 はイメージとコンテナ用で、SD カードの容量は小さい

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags docker
```

## ファイル共有（roles/sftpgo）

[SFTPGo](https://github.com/drakkan/sftpgo) を Docker で動かし、USB のディレクトリ（既定 `/mnt/data/encoded`）を LAN に公開する。ブラウザ（Web クライアント）に加えて、REST API と WebDAV で一覧・取得・アップロードができる。`sftpgo` グループのホスト（`hosts.yml`）だけに適用する。

| 構成 | 内容 |
|---|---|
| `/opt/sftpgo/compose.yml` | docker compose の定義（イメージのバージョンは `sftpgo_image` で固定） |
| `/opt/sftpgo/users.json` | ユーザーの定義（`sftpgo_users` から生成。`root:<gid>` の `0640`） |
| `/etc/systemd/system/sftpgo.service` | `docker compose up` / `down` を行う。`RequiresMountsFor` で USB のマウントを待つ |
| `sftpgo_tmp_dir`（既定 `/mnt/data/.sftpgo-tmp`） | アップロード中の一時ファイル（コンテナの `/tmp`） |
| Docker の volume `sftpgo_data` | SFTP のホスト鍵（SFTP を有効にした場合） |

| 変数 | 既定 | 内容 |
|---|---|---|
| `sftpgo_image` | `drakkan/sftpgo:v2.7.6` | イメージ（バージョンを固定する） |
| `sftpgo_share_dir` | `/mnt/data/encoded` | 公開するディレクトリ（USB の ext4 上） |
| `sftpgo_tmp_dir` | `/mnt/data/.sftpgo-tmp` | 一時ファイルの置き場所（USB 上、`sftpgo_share_dir` の外） |
| `sftpgo_uid` / `sftpgo_gid` | `1000` / `1000` | コンテナの UID / GID（アップロードしたファイルの所有者） |
| `sftpgo_http_port` | `8080` | REST API と Web クライアント（`0` で無効） |
| `sftpgo_webdav_port` | `10080` | WebDAV（`0` で無効） |
| `sftpgo_sftp_port` | `0` | SFTP（`0` で無効。22 は sshd が使う） |
| `sftpgo_allowed_networks` | `[]` | 接続を許可するネットワーク（CIDR）。空なら制限しない |
| `sftpgo_users` | `[]` | ユーザーの一覧（`name` / `password_hash` / `permissions` / `allowed_networks`） |

ユーザーは `host_vars/<host>.yml` に書き、パスワードのハッシュは vault に置く。

```yaml
sftpgo_allowed_networks: [192.168.10.0/24]
sftpgo_users:
  - name: client
    password_hash: "{{ vault_sftpgo_client_password_hash }}"  # openssl passwd -6 で生成し、vault に置く
    permissions:          # パスごとの権限（SFTPGo の permissions）
      /: [list, download, upload, create_dirs]
```

- 権限は `list`（一覧）、`download`、`upload`（新規のみ）、`overwrite`（上書き）、`delete`、`rename`、`create_dirs` など。`"*"` は全権限。`/sub` のようにパスごとに変えられる
- ユーザーは `users.json` だけで定義する（SFTPGo の memory プロバイダ。DB を持たない）。`sftpgo_users` から消したユーザーはログインできなくなる。Web 管理画面は無効にしている。管理者は無効（status 0）なものを 1 人だけ置く（管理者が 1 人もいないと、Web クライアントが初期設定画面にリダイレクトされて使えないため）
- Web クライアントでの共有リンク（ログインなしでアクセスできる）、パスワードの変更、二要素認証などは無効にしている（再起動で消えるため）
- アップロードはアトミック（同じディレクトリの `.sftpgo-upload.*` に書き、完了したらリネームする）。途中のファイルは元の名前では現れない。コンテナが強制終了した場合などに `.sftpgo-upload.*` が残ることがある
- multipart のアップロード（Web クライアントからのアップロード、`POST /api/v2/user/files`）は、一時ファイルを `sftpgo_tmp_dir` に書いてから移す。SD カードには書かない
- 実行前に、`docker compose` が使えること、`sftpgo_share_dir` と `sftpgo_tmp_dir` の親が USB の ext4（`/` 以外のマウント）上にあることを確認する（満たさなければ何も変更せずに失敗する）。UID `sftpgo_uid` が `sftpgo_share_dir` に書き込めない場合は `[要確認]` を表示する（chown はしない）
- bind mount は `create_host_path: false` にし、systemd のユニットで USB のマウントを待つ。USB がマウントされていなければ起動しない（SD カード上のディレクトリを公開しない）
- `compose.yml` / `users.json` を変更すると、`sftpgo.service` を再起動してコンテナを作り直す（接続中の転送は切れる）
- 最後に、コンテナの bind mount が 3 つ（`sftpgo_share_dir`、`sftpgo_tmp_dir`、`users.json`）だけであること、`users.json` を読み込めたこと（ログに `data loading failed` がないこと）、`/healthz` が `ok` を返すことを確認する
- vault を読み込むため、実行には `--ask-vault-pass` が必要。vault は `sftpgo` タグのタスクでだけ読み込むので、`--tags docker` などでは不要
- 単独で実行する場合は `--tags sftpgo`

```sh
openssl passwd -6                                  # パスワードのハッシュを生成
ansible-vault edit inventories/home/vault.yml      # vault_sftpgo_client_password_hash を追加
ansible-playbook playbooks/site.yml --limit rpi-01 --tags sftpgo --ask-vault-pass
```

クライアントからの使い方（`client` ユーザーの場合）:

```sh
B=http://192.168.10.55:8080

# トークン（20 分有効）を取得する
T=$(curl -s -u client:PASSWORD $B/api/v2/user/token | jq -r .access_token)

# 一覧
curl -s -H "Authorization: Bearer $T" "$B/api/v2/user/dirs?path=/カネオくん" | jq

# 取得（Range に対応するので -C - で再開できる）
curl -H "Authorization: Bearer $T" -o out.mp4 "$B/api/v2/user/files?path=/カネオくん/xxx.mp4"

# アップロード（本文をそのまま送る）
curl -H "Authorization: Bearer $T" --data-binary @file.mp4 "$B/api/v2/user/files/upload?path=/uploads/file.mp4"
```

- API の仕様: `http://192.168.10.55:8080/openapi/`（Swagger UI）
- ブラウザ: `http://192.168.10.55:8080/`（Web クライアント）
- WebDAV: `http://192.168.10.55:10080/`（Finder の「サーバへ接続」など）

運用規約:

- 公開するディレクトリは `/mnt/data` 配下の必要なものに限定する。NTFS（`/mnt/share`）は対象外とする
- 認証を必須にする（匿名アクセスを許可しない）。`sftpgo_allowed_networks` で LAN に限定する
- 削除・上書きの権限（`delete` / `overwrite` / `rename`）は必要なユーザーにだけ与える。API からの削除は取り消せない
- Pi 上の処理（エンコードなど）と API が同じディレクトリに同時に書き込む場合は、書き込み先を分ける（例: API は `uploads/` に書く）

## 録画サーバー（roles/epgstation）

[docker-mirakurun-epgstation](https://github.com/l3tnun/docker-mirakurun-epgstation) をもとに、[Mirakurun](https://github.com/Chinachu/Mirakurun)（チューナーの管理）+ MariaDB + [EPGStation](https://github.com/l3tnun/EPGStation)（予約・録画・エンコード・視聴）を Docker で動かす。`epgstation` グループのホスト（`hosts.yml`）だけに適用する。upstream の `setup.sh` は使わず、compose.yml と設定ファイルを role のテンプレートから生成する。

| 機器 | 内容 |
|---|---|
| チューナー | PX-S1UD V2.0（地上デジタル専用・1 チューナー）。カーネル標準の DVB ドライバ（`smsusb`）で `/dev/dvb/adapter0` になる |
| カードリーダー | USB の CCID（GemPC Twin など）。B-CAS カードはコンテナ内の pcscd で読む |
| エンコーダ | Pi 4 のハードウェアエンコーダ（`h264_v4l2m2m`、`/dev/video10`〜`12`） |

| 構成 | 内容 |
|---|---|
| `/opt/epgstation/compose.yml` | docker compose の定義（DB のパスワードを含むため `root` の `0600`） |
| `/opt/epgstation/build/` | EPGStation のイメージの Dockerfile と `ffmpeg-hls`（Pi 上でビルドする） |
| `/opt/epgstation/mirakurun/` | Mirakurun の `tuners.yml` / `channels.yml` / `server.yml` |
| `/opt/epgstation/epgstation/` | EPGStation の `config.yml`（`root:<gid>` の `0640`）/ `enc.js` / ログの設定 |
| `/etc/systemd/system/epgstation.service` | `docker compose up` / `down` を行う。`RequiresMountsFor` で USB のマウントを待つ |
| `epgstation_recorded_dir`（既定 `/mnt/data/recorded`） | 録画データ（EPGStation の `/app/recorded`） |
| `epgstation_data_dir`（既定 `/mnt/data/epgstation`） | 予約情報・HLS の一時ファイル（`data`）、サムネイル（`thumbnail`）、ドロップログ（`drop`） |
| `epgstation_mirakurun_data_dir`（既定 `/mnt/data/mirakurun`） | Mirakurun の EPG・チャンネルのキャッシュ |
| Docker の volume `epgstation_db` | MariaDB のデータ（p3） |
| Docker の volume `epgstation_mirakurun-opt` | Mirakurun が初回の起動時にビルドする B25 デコーダ（`arib-b25-stream-test`） |
| `/lib/firmware/isdbt_rio.inp` | PX-S1UD のファームウェア |

| 変数 | 既定 | 内容 |
|---|---|---|
| `epgstation_mirakurun_image` | `chinachu/mirakurun:4.1.5` | Mirakurun のイメージ（バージョンを固定する） |
| `epgstation_mariadb_image` | `mariadb:10.11.19` | MariaDB のイメージ |
| `epgstation_base_image` | `l3tnun/epgstation:v2.10.0-debian` | EPGStation のイメージ（ffmpeg を追加してビルドする） |
| `epgstation_recorded_dir` | `/mnt/data/recorded` | 録画データ（USB の ext4 上） |
| `epgstation_encoded_dir` | `""` | エンコード後のファイルの置き場所。空なら録画データと同じ |
| `epgstation_data_dir` | `/mnt/data/epgstation` | EPGStation のデータ |
| `epgstation_mirakurun_data_dir` | `/mnt/data/mirakurun` | Mirakurun のデータ |
| `epgstation_uid` / `epgstation_gid` | `1000` / `1000` | EPGStation の UID / GID（録画ファイルの所有者） |
| `epgstation_http_port` | `8888` | EPGStation（`0` で無効） |
| `epgstation_mirakurun_port` | `40772` | Mirakurun（`0` で無効） |
| `epgstation_db_password` | `vault_epgstation_db_password` | MariaDB の epgstation ユーザーのパスワード（8 文字以上） |
| `epgstation_tuners` | PX-S1UD（adapter 0） | チューナーの一覧（`name` / `types` / `adapter`） |
| `epgstation_channels` | `[]` | チャンネルの一覧。空ならチャンネルスキャンの結果をそのまま使う |
| `epgstation_require_card_reader` | `true` | カードリーダーがなければ失敗させる |
| `epgstation_encode_height` | `720` | エンコード後の高さ |
| `epgstation_encode_video_bitrate` / `_audio_bitrate` | `3000k` / `192k` | エンコード後のビットレート |

- 実行前に次を確認する（満たさなければ何も変更せずに失敗する）
  - `docker compose` が使える
  - チューナー（`/dev/dvb/adapter<N>/frontend0`）、ハードウェアエンコーダ（`/dev/video10`〜`12`）、カードリーダー（USB の interface class `0x0b`）がある
  - 録画データ・データのディレクトリの親が USB の ext4（`/` 以外のマウント）上にある
  - 録画データのディレクトリが既にある場合は、UID `epgstation_uid` が書き込める（chown はしない。書き込めなければ手作業で所有者を変更する）
- ホストの pcscd は止めてマスクする。B-CAS カードはコンテナ内の pcscd で読む（ホストとコンテナでカードリーダーを取り合わないようにするため）。ホストの pcscd（Trixie の pcsc-lite 2.x）はコンテナの libpcsclite（Bookworm の 1.9.9）とプロトコルのバージョンが違うので、ホストの pcscd をコンテナと共有することもできない。そのため、ホストに `pcscd` / `libccid` / `pcsc-tools` などは入れない
- PX-S1UD のファームウェアがなければ、PLEX のドライバ（zip）から取り出して `/lib/firmware` に置き、1 回だけ再起動して読み込ませる（zip とファームウェアはチェックサムで確認する）。`modprobe -r smsusb` でドライバを外すと、カーネルの警告が出た後にチューナーが USB のエラーで切断されることがあったため、読み込み直しは行わない
- チューナーは `/dev/dvb` の bind mount でコンテナに渡す。チューナーを挿し直した場合や USB のエラーで再認識された場合は、`/dev/dvb` が作り直されてコンテナから見えなくなるので、`sudo systemctl restart epgstation` を実行する（カードリーダーは挿し直してもそのまま使える）
- EPGStation のイメージには、Debian の ffmpeg（`h264_v4l2m2m` を含む）を追加してビルドする（upstream のように ffmpeg をソースからビルドすると、Pi では時間がかかるため）。Dockerfile か `ffmpeg-hls` が変わるとイメージのタグが変わり、ビルドし直す。古いイメージは `docker image prune` で消す
- エンコード（`enc.js`）は `h264_v4l2m2m` で mp4（1280x720、正方形の画素）にする。MPEG-2 のデコードとインターレース解除は CPU で行う（実測で 0.8〜1 倍速。1 時間の番組に 1 時間強かかる）。字幕は mp4 に入れない
- エンコード・配信の音声は主音声（`0:a:0`）だけにする。放送の 2 本目以降の音声は途中で途切れることがあり、すべて指定すると ffmpeg がその音声を待ち続けて終わらない（SIGTERM でも止まらない）。二か国語放送（デュアルモノ）は、主音声を左右に分けて 2 本にする
- 配信は次の 2 つだけにする（libx264 / libvpx のソフトウェアエンコードは Pi 4 では間に合わない）
  - ライブ: m2ts（720p、無変換）と HLS（720p、480p）
  - 録画: HLS（720p、480p）
- `h264_v4l2m2m` は SPS/PPS を最初の 1 回しか出力しないため、そのまま HLS に分割すると 2 つ目以降のセグメントを単独で再生できない（途中からの再生やライブ視聴ができない）。HLS の配信は `ffmpeg-hls` を通す。`ffmpeg-hls` はエンコード結果を mpegts で別の ffmpeg に渡し、`-bsf:v dump_extra` でキーフレームごとに SPS/PPS を付け直してから分割する
- ログはファイルに書かず、標準出力（Docker の json-file、daemon.json でローテーション）に出す
- 設定ファイル・compose.yml を変更すると `epgstation.service` を再起動する。**録画中・配信中のものは止まる**ので、録画のない時間に実行する
- 最後に、コンテナが 3 つとも起動していること、Mirakurun のチューナーが使えること、コンテナ内で B-CAS カードを読めること、EPGStation の UID でハードウェアエンコーダを使えること、EPGStation の API が応答することを確認する
- vault を読み込むため、実行には `--ask-vault-pass` が必要。チューナー・カードリーダーの実機が必要なため `hardware` タグを付けている。単独で実行する場合は `--tags epgstation`

```sh
ansible-vault edit inventories/home/vault.yml      # vault_epgstation_db_password を追加
ansible-playbook playbooks/site.yml --limit rpi-01 --tags epgstation --ask-vault-pass
```

チャンネルスキャン（初回とチャンネルが変わったときだけ。地上波で数分〜十数分かかる）:

```sh
# Mirakurun が channels.yml を書き換え、そのまま使われる
curl -X PUT "http://192.168.10.55:40772/api/config/channels/scan?type=GR&setDisabledOnAdd=false&refresh=true"
```

スキャンの結果を固定する場合は、`/opt/epgstation/mirakurun/channels.yml` の内容を `host_vars` の `epgstation_channels` に書く（以降は Ansible が channels.yml を書き、スキャンで書き換えても次の実行で元に戻る）。

- ブラウザ: `http://192.168.10.55:8888/`（EPGStation）
- Mirakurun: `http://192.168.10.55:40772/`

運用規約:

- **EPGStation の「クリーンアップ」（`POST /api/recorded/cleanup`）は、録画ディレクトリにある DB に登録されていないファイルをすべて削除する。** `epgstation_recorded_dir` に EPGStation の外で作ったファイル（導入前からある録画など）がある場合は実行しない。`epgstation_encoded_dir` は専用のディレクトリにし、他の用途のファイルがある場所（SFTPGo で公開している `/mnt/data/encoded` など）は指定しない（role でも `sftpgo_share_dir` は指定できないようにしている）
- EPGStation には認証がないので、LAN の外に公開しない
- チューナーは 1 つなので、同時に録画・視聴できるのは 1 番組だけ。予約が重なった場合は EPGStation の競合表示で確認する。BS/CS を録画する場合は、対応するチューナーを追加して `epgstation_tuners` に書く
- 録画データの容量を監視する（`/mnt/data` の空き容量）
- チューナーやカードリーダーの消費電力が大きい場合は、セルフパワーの USB ハブを使う
- DB のパスワードは、DB の初期化時（volume が空のとき）にだけ使われる。後から変える場合は、MariaDB のユーザーのパスワードも手作業で変える

## メディアサーバー（roles/plex）

[Plex Media Server](https://www.plex.tv/) の公式イメージ（[plexinc/pms-docker](https://github.com/plexinc/pms-docker)）を Docker で動かし、USB のディレクトリ（既定 `/mnt/data/encoded`）をライブラリとして LAN に配信する。`plex` グループのホスト（`hosts.yml`）だけに適用する。**LAN の中だけで使う**（リモートアクセス・Relay は無効にする）。

| 構成 | 内容 |
|---|---|
| `/opt/plex/compose.yml` | docker compose の定義（イメージのバージョンは `plex_image` で固定。`network_mode: host`） |
| `/etc/systemd/system/plex.service` | `docker compose up` / `down` を行う。`RequiresMountsFor` で USB のマウントを待つ |
| `plex_data_dir`/`config`（既定 `/mnt/data/plex/config`） | DB・メタデータ・サムネイル・`Preferences.xml`（コンテナの `/config`） |
| `plex_data_dir`/`transcode`（既定 `/mnt/data/plex/transcode`） | トランスコードの一時ファイル（コンテナの `/transcode`） |
| `plex_media_dirs` の `source` | ライブラリ（コンテナの `/data/<name>` に読み取り専用でマウントする） |

| 変数 | 既定 | 内容 |
|---|---|---|
| `plex_image` | `plexinc/pms-docker:1.43.4.10903-e5521bd8c` | イメージ（バージョンを固定する） |
| `plex_data_dir` | `/mnt/data/plex` | Plex のデータ（USB の ext4 上） |
| `plex_media_dirs` | `[{name: encoded, source: /mnt/data/encoded}]` | ライブラリにするディレクトリ（USB の ext4 上） |
| `plex_uid` / `plex_gid` | `1000` / `1000` | Plex の UID / GID（`plex_data_dir` の所有者） |
| `plex_cpu_shares` | `512` | CPU の配分の重み（Docker の既定は `1024`）。cgroup v2 の `cpu.weight` では 59（既定は 100） |
| `plex_preferences` | 下記 | サーバーの設定（Plex の API で設定する） |

`plex_preferences` の既定（画面で変えても次の実行で戻る。ここにない設定は画面で変えてよい）:

| 設定 | 値 | 内容 |
|---|---|---|
| `PublishServerOnPlexOnlineKey` | `false` | リモートアクセス（UPnP でルーターのポートを開ける）を無効にする |
| `RelayEnabled` | `false` | Relay（plex.tv 経由の中継。ポートを開けなくても外から使える）を無効にする |
| `DlnaEnabled` | `false` | DLNA（認証なしでライブラリを LAN に公開する）を無効にする |
| `FSEventLibraryUpdatesEnabled` | `true` | ファイルが追加されたら自動でスキャンする |
| `GenerateBIFBehavior` / `GenerateChapterThumbBehavior` / `LoudnessAnalysisBehavior` | `never` | ビデオプレビューのサムネイル・チャプターのサムネイル・音量の解析をしない（Pi の CPU では重い） |

- Pi では Plex のハードウェアトランスコードは使えない（Plex が Pi のエンコーダに対応していない）。ソフトウェアのトランスコードは 720p でも間に合わないことがあるので、**ダイレクト再生（とコンテナの変換だけのダイレクトストリーム）を前提にする**。ライブラリの動画（H.264 / AAC の mkv・mp4）はそのまま再生できる。クライアントの画質の設定は「オリジナル」にする（下げるとトランスコードになる）
- 実行前に、`docker compose` が使えること、`plex_data_dir` の親とライブラリのディレクトリが USB の ext4（`/` 以外のマウント）上にあること、UID `plex_uid` がライブラリのディレクトリを読めることを確認する（満たさなければ何も変更せずに失敗する。chown はしない）
- `network_mode: host` で動かす（LAN 内のクライアントからの自動検出（GDM、32410〜32414/udp）のため）。Web と API は 32400/tcp
- `plex_preferences` は Plex の API（`/:/prefs`）で読み書きする（再起動しない）。`Preferences.xml` を直接書き換えないのは、Plex が既定値の設定をファイルから消して書き戻すため。サーバーを登録した後は、`Preferences.xml` のサーバーのトークン（`PlexOnlineToken`）で API を使う
- EPGStation と同じ Pi で動かすため、CPU の重みを下げている（録画・エンコードと取り合ったときに譲る）。メモリの上限は設定しない（Pi の cgroup ではメモリのコントローラが無効）
- `compose.yml` を変更すると `plex.service` を再起動してコンテナを作り直す（再生中のものは止まる）
- 最後に、コンテナがホストのネットワークで起動していること、bind mount が `plex_data_dir` の下とライブラリだけで、ライブラリが読み取り専用であること、Plex のユーザーでライブラリを読めること、`plex_preferences` が反映されていることを確認する。サーバーが未登録なら `[要確認]` を表示する
- コンテナのログに出る `Critical: libusb_init failed` は、USB のチューナー（Plex の DVR 機能）を探せないだけなので無視してよい
- vault は使わない。単独で実行する場合は `--tags plex`

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags plex
```

初回だけ、サーバーを Plex のアカウントに登録する（未登録のサーバーは LAN の他の PC からは設定できないことがあるので、Pi 自身（127.0.0.1）として接続する）:

```sh
# Mac から SSH のポートフォワードで接続したまま、ブラウザで http://127.0.0.1:32400/web を開く
ssh -o HostKeyAlias=rpi-01 -i ~/.ssh/id_ed25519_rp4 -L 32400:127.0.0.1:32400 genius@192.168.10.55
```

1. Plex のアカウントでサインインし、サーバーに名前を付ける
2. ライブラリを追加する（種類は「その他のビデオ」か「テレビ番組」、フォルダはコンテナ内のパス `/data/encoded`）
3. 登録したら、もう一度 Ansible を実行する（`[要確認]` が出ないこと、設定が戻っていないことを確認する）

以降は LAN 内のクライアント（Plex のアプリ、ブラウザの `http://192.168.10.55:32400/web`）から、同じアカウントでサインインして使う。

運用規約:

- **リモートアクセス・Relay を有効にしない**（LAN の外に公開しない）。画面で有効にしても、次の Ansible の実行で無効に戻る
- ライブラリは読み取り専用でマウントする。Plex から動画を削除・変更しない（「メディアの削除を許可」は使えない）。最適化（Optimize）・同期も Pi の CPU では使わない
- ライブラリにするディレクトリは `/mnt/data` 配下の必要なものに限定する。NTFS（`/mnt/share`）は対象外とする
- Plex のデータ（`/mnt/data/plex`）の容量を監視する（ライブラリが大きくなると数 GB になる）

## 監視（roles/alloy）

[Grafana Alloy](https://grafana.com/docs/alloy/latest/) をホストに apt で導入し、ストレージの容量・CPU の温度・CPU・メモリの使用率を Grafana Cloud（無料枠）の Prometheus に送る。`monitoring` グループのホスト（`hosts.yml`）だけに適用する。ダッシュボード・アラート（Slack への通知）は Terraform で管理する（「ダッシュボード・アラート（terraform/grafana-cloud）」を参照）。

| 構成 | 内容 |
|---|---|
| `/etc/apt/sources.list.d/grafana.sources` | Grafana の apt リポジトリ（`apt.grafana.com`） |
| `/etc/alloy/config.alloy` | Alloy の設定（収集 → ラベル付け → filesystem の絞り込み → 送信） |
| `/etc/alloy/grafana-cloud-token` | Grafana Cloud のトークン（`root:alloy` の `0640`。`config.alloy` の `local.file` で読み込む） |
| `/etc/systemd/system/alloy.service.d/10-raspberry-pi.conf` | ExecStart を置き換え、WAL を `/run/alloy/data`（tmpfs）に置き、UI を `127.0.0.1:12345` だけで待ち受ける |

| 変数 | 既定 | 内容 |
|---|---|---|
| `alloy_version` | `1.20.1` | Alloy のバージョン（パッケージは hold する） |
| `alloy_remote_write_url` / `_username` / `_token` | （`group_vars/monitoring` から vault を参照） | Grafana Cloud の Prometheus の送信先・インスタンス ID・トークン |
| `alloy_instance` | `inventory_hostname` | `instance` ラベル（`rpi-01` など） |
| `alloy_job` | `integrations/node_exporter` | `job` ラベル（Grafana Cloud の Linux Server インテグレーションと同じ） |
| `alloy_scrape_interval` | `60s` | 収集の間隔（Grafana Cloud の 1 DPM に合わせる。短くしない） |
| `alloy_collectors` | `cpu`, `meminfo`, `loadavg`, `filesystem`, `thermal_zone`, `hwmon`, `uname` | 有効にするコレクタ（ほかは無効） |
| `alloy_filesystem_mount_points` | `/`, `/var/lib/docker`, `/mnt/data`, `/mnt/share` | 容量を送るマウント先（SD カードの p2・p3 と USB） |

| 見たいもの | メトリクス |
|---|---|
| ストレージの容量 | `node_filesystem_avail_bytes` / `node_filesystem_size_bytes`（`mountpoint` ラベル） |
| CPU の温度 | `node_thermal_zone_temp{type="cpu-thermal"}`（`node_hwmon_temp_celsius` も同じ値） |
| 低電圧の警告 | `node_hwmon_in_lcrit_alarm_volts{chip="soc:firmware_raspberrypi_hwmon"}`（1 で低電圧） |
| CPU 使用率 | `node_cpu_seconds_total` |
| メモリ使用率 | `node_memory_MemAvailable_bytes` / `node_memory_MemTotal_bytes` |

- **WAL を SD カードに書かない**: パッケージの ExecStart（`/usr/lib/alloy/alloy-wrapper`）は `--storage.path=/var/lib/alloy/data` を固定で付けるため、drop-in で `alloy run` を直接起動し、`/run/alloy/data`（tmpfs）に置く。サービスの再起動では消えないが（`RuntimeDirectoryPreserve`）、OS の再起動で未送信のデータとともに消える。rpi-01 では 1 分に約 130 系列で、WAL は数十 KB
- USB のマウントは待たない（USB が外れても、SD カードの容量・温度などは送り続ける）
- exporter はマウント先を除外の正規表現でしか絞れないため、`prometheus.relabel` で `alloy_filesystem_mount_points` 以外の `node_filesystem_*` を捨てる（`/run`・`/tmp`・`/boot/firmware` などは送らない）
- 匿名の利用統計の送信（`--disable-reporting`）は無効にしている
- `config.alloy` は `alloy validate` で検証してから置く。drop-in・`config.alloy`・トークンを変更すると Alloy を再起動する
- パッケージは hold し、`apt upgrade`（unattended-upgrades を含む）でバージョンが変わらないようにする。上げるときは `alloy_version` を変える
- 最後に、Alloy の全コンポーネントが正常であること、`127.0.0.1:12345` 以外で待ち受けていないこと、WAL が tmpfs 上にあること、Grafana Cloud への送信に成功していること（`prometheus_remote_storage_samples_total` − `prometheus_remote_storage_samples_failed_total` が 0 より大きい）を確認する。トークンの誤り（401）などで送信できなければ失敗させる
- `--check` では、Alloy が未インストールの場合はインストールの予定を表示してそこで止まる
- 単独で実行する場合は `--tags alloy`（または `--tags monitoring`）

事前準備（初回だけ）:

1. [Grafana Cloud](https://grafana.com/) のアカウントとスタックを作る（無料枠ではスタックは 1 つ）
2. grafana.com の My Account → スタック → Prometheus の「Details」で、Remote Write Endpoint（`https://.../api/prom/push`）と Username / Instance ID（数字）を確認する
3. Grafana Cloud の Administration → Users and access → Cloud access policies で、Realm をスタック、スコープを **metrics:write だけ**にしたアクセスポリシーを作り、「Add token」でトークンを発行する
4. vault に追加する（項目は `vault.yml.example` を参照）
   ```sh
   ansible-vault edit inventories/home/vault.yml
   # vault_grafana_cloud_prometheus_url / vault_grafana_cloud_prometheus_username / vault_grafana_cloud_metrics_token
   ```

```sh
ansible-playbook playbooks/site.yml --limit rpi-01 --tags alloy --ask-vault-pass
```

送られているメトリクスは、Grafana Cloud の Explore で `{instance="rpi-01"}` などを指定して確認する。使用量（アクティブ系列）は Administration → Cost management（Usage）で確認する。

運用規約:

- Grafana Cloud のトークンは `metrics:write` だけにする（読み取りや管理の権限を付けない）。Terraform（terraform/grafana-cloud）のトークンとは分ける
- 容量を送るマウント先を増やすときは `alloy_filesystem_mount_points` に追加する（絞り込みを外して全部送らない）
- アプリのログの収集はこの role の対象外（別 Issue で扱う）

## ダッシュボード・アラート（terraform/grafana-cloud）

roles/alloy が送るメトリクスのダッシュボードとアラートを、Grafana Cloud に [Terraform の Grafana プロバイダ](https://registry.terraform.io/providers/grafana/grafana/latest/docs)で作る。容量不足・高温・メモリ不足・低電圧・Pi の停止を Slack に通知する。Ansible の `grafana.grafana` コレクションにはアラートルールのモジュールがないため、Terraform を使う（`terraform plan` で差分を確認でき、コードから消したリソースは Grafana Cloud からも消える）。

| リソース | 内容 |
|---|---|
| `grafana_folder.raspberry_pi` | フォルダ「Raspberry Pi」（ダッシュボードとアラートルールを置く） |
| `grafana_dashboard.raspberry_pi` | ダッシュボード「Raspberry Pi」（`dashboards/raspberry-pi.json.tftpl`） |
| `grafana_contact_point.slack` | Slack の通知先（Incoming Webhook） |
| `grafana_notification_policy.root` | 通知ポリシー（すべてのアラートを Slack に送る。スタックに 1 つだけ） |
| `grafana_rule_group.raspberry_pi` | アラートルール（1 分ごとに評価する） |
| `data.grafana_data_source.prometheus` | Grafana Cloud の Prometheus（スタックに最初からある。名前で参照し、UID は直書きしない） |

ダッシュボード（`instance` を変数にしていて、ホストを切り替えられる）:

- CPU 使用率・メモリ使用率・CPU の温度（現在の値のゲージと推移）
- 低電圧（表示している期間に `rpi_volt` の警告があったか）
- ストレージ（`/`・`/var/lib/docker`・`/mnt/data`・`/mnt/share`）の使用率・空き容量・空き容量の推移
- ゲージの赤はアラートのしきい値（変数）に合わせる

アラートルール（しきい値・継続時間は変数。Slack の通知文には summary のホスト名・マウント先・現在の値が入る）:

| ルール | 条件（既定） | 変数 |
|---|---|---|
| 空き容量の不足 | 空き容量（`avail / size`）が 10% 未満の状態が 5 分続く（マウント先ごと） | `disk_free_percent` / `disk_free_for` |
| CPU の高温 | CPU の温度が 75℃ を超えた状態が 5 分続く | `cpu_temp_celsius` / `cpu_temp_for` |
| メモリの不足 | 使えるメモリ（`MemAvailable / MemTotal`）が 10% 未満の状態が 5 分続く | `memory_available_percent` / `memory_available_for` |
| メトリクスが届かない | `instances` のホストのメトリクスが 10 分届かない（Pi の停止・ネットワーク断・Alloy の停止） | `instances` / `no_metrics_for` |
| 低電圧 | `rpi_volt` の低電圧の警告（スロットリングの原因）を検知した | `undervoltage_for` |

| 変数 | 既定 | 内容 |
|---|---|---|
| `grafana_url` | （必須・sensitive） | スタックの URL（`https://<stack>.grafana.net`） |
| `grafana_auth` | （必須・sensitive） | Terraform 用のサービスアカウントのトークン |
| `slack_webhook_url` | （必須・sensitive） | Slack の Incoming Webhook の URL |
| `prometheus_data_source_name` | `grafanacloud-<stack>-prom` | Prometheus のデータソース名（スタックの URL から決める） |
| `job` | `integrations/node_exporter` | `job` ラベル（roles/alloy の `alloy_job`） |
| `instances` | `["rpi-01"]` | 停止を検知するホスト（roles/alloy を適用したホスト） |
| `repeat_interval` | `4h` | 同じアラートを繰り返し通知する間隔 |

- Pi が止まるとほかのルールはデータがなくなるが、通知は「メトリクスが届かない」だけにする（ほかのルールの `no_data_state` は `OK`）。クエリの失敗は `Error`（DatasourceError）として通知する
- 「メトリクスが届かない」は `absent_over_time` で判定するため、ホストを `instances` に並べる（Alloy を適用したホストを増やしたら追加する）。USB が外れてマウント先のメトリクスが届かなくなった場合は、このルールでは検知しない
- 高温によるスロットリング（85℃ から）は、その手前の「CPU の高温」で通知する
- アラートはフォルダと名前でまとめて（`group_by`）、30 秒待ってから送る
- Terraform で作ったアラートルール・通知先・通知ポリシーは画面では編集できない（provisioned）。ダッシュボードは画面で変えられるが、次の `apply` で戻る
- state はローカル（`terraform/grafana-cloud/terraform.tfstate`）に置く。Webhook URL などが含まれるため Git 管理外（`.gitignore`）にし、消さないこと（消すと既存のリソースを管理できなくなる）

事前準備（初回だけ。スタックは roles/alloy の事前準備で作ったものを使う。Terraform では管理しない）:

1. Grafana Cloud のスタック（`https://<stack>.grafana.net`）の Administration → Users and access → Service accounts で、Terraform 専用のサービスアカウント（Role は Admin）を作り、「Add service account token」でトークン（`glsa_...`）を発行する
2. Slack で通知を送るチャンネルの Incoming Webhook を作り、URL（`https://hooks.slack.com/services/...`）を控える
3. Terraform（1.14 系）をインストールする（`brew install terraform` など）
4. `terraform.tfvars` を作る（`TF_VAR_grafana_url` などの環境変数で渡してもよい）
   ```sh
   cd terraform/grafana-cloud
   cp terraform.tfvars.example terraform.tfvars
   # grafana_url / grafana_auth / slack_webhook_url を設定する
   ```

```sh
cd terraform/grafana-cloud
terraform init
terraform plan    # 差分を確認する
terraform apply
terraform plan    # 続けて実行すると差分がない（No changes）
```

通知を確認するときは、`terraform.tfvars` でしきい値を一時的に変えて（例: `cpu_temp_celsius = 30`、`cpu_temp_for = "0s"`）`apply` すると Slack に通知が届き、戻して `apply` すると解決（Resolved）の通知が届く。`sudo systemctl stop alloy` で Alloy を止めると、10 分後に「メトリクスが届かない」が通知される。

運用規約:

- ダッシュボード・アラート・通知の変更は Terraform で行う（画面で変えても次の `apply` で戻る）。ダッシュボードを画面で作り直した場合は、JSON を書き出して `dashboards/raspberry-pi.json.tftpl` に反映する（`${...}` は Terraform が埋めるため、Grafana の変数は `$instance` の形で書く）
- サービスアカウントのトークンは Terraform 専用にし、Alloy のトークン（`metrics:write` だけ）とは分ける
- Terraform・プロバイダのバージョンを上げるときは `versions.tf` を変え、`terraform init -upgrade` と `terraform providers lock -platform=darwin_arm64 -platform=darwin_amd64 -platform=linux_amd64 -platform=linux_arm64` で `.terraform.lock.hcl` を更新してコミットする
- アプリのログのアラートはここでは扱わない（ログの収集の Issue で扱う）

## Raspberry Pi を追加する

1. `inventories/home/hosts.yml` にホストを追加
2. `inventories/home/host_vars/<hostname>.yml` を作成
3. 上記「SD カードを準備する」の手順で SD カードを作成
4. 用途別の設定が必要なら `roles/<role>/` を作り、グループと playbook に紐づける

## 使い方

```sh
ansible-galaxy collection install -r requirements.yml

# 全台（sftpgo・epgstation・monitoring グループのホストがあるため vault のパスワードが必要）
ansible-playbook playbooks/site.yml --ask-vault-pass

# 特定のホストだけ
ansible-playbook playbooks/site.yml --limit rpi-01
```
