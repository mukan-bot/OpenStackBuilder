# OpenStack DevStack Auto-Deployment Scripts

このリポジトリには、OpenStack DevStackを自動デプロイするためのスクリプトが含まれています。

## 概要

- `deploy_controller.sh`: コントローラーノードをデプロイ
- `deploy_compute.sh`: コンピュートノードをデプロイ
- 完全に自動化されたセットアップ
- エラーハンドリングとログ出力
- マルチアーキテクチャ対応（x86_64/aarch64）

## 前提条件

- Ubuntu 20.04 LTS以降
- 最低4GB RAM（コントローラーは8GB推奨）
- 最低20GB空きディスク容量
- インターネット接続
- sudo権限

## 使用方法

### 1. コントローラーノードのデプロイ

```bash
# 基本的な使用方法
sudo bash deploy_controller.sh

# パスワードを指定
sudo bash deploy_controller.sh --password MySecurePassword123

# 特定のDevStackブランチを指定
sudo bash deploy_controller.sh --branch stable/2024.1
```

#### オプション
- `--password PASSWORD`: 管理者パスワード（デフォルト: OpenStack123）
- `--branch BRANCH`: DevStackブランチ（デフォルト: master）
- `--help`: ヘルプを表示

### 2. コンピュートノードのデプロイ

```bash
# 基本的な使用方法（コントローラーIPは必須）
sudo bash deploy_compute.sh --controller 192.168.1.100

# 全オプション指定
sudo bash deploy_compute.sh \
  --controller 192.168.1.100 \
  --password MySecurePassword123 \
  --branch stable/2024.1 \
  --public-if eth1
```

#### オプション
- `--controller IP`: コントローラーノードのIPアドレス（必須）
- `--password PASS`: 管理者パスワード（デフォルト: OpenStack123）
- `--branch BRANCH`: DevStackブランチ（デフォルト: master）
- `--public-if INTERFACE`: パブリックネットワーク用インターフェース（任意）
- `--help`: ヘルプを表示

### 3. マルチノードセットアップ手順

1. **コントローラーノードをデプロイ**:
   ```bash
   sudo bash deploy_controller.sh --password OpenStack123
   ```

2. **コンピュートノードをデプロイ**:
   ```bash
   sudo bash deploy_compute.sh --controller <CONTROLLER_IP> --password OpenStack123
   ```

3. **コントローラーでコンピュートノードを発見**:
   ```bash
   # コントローラーノードで実行
   sudo -u stack bash
   cd ~/devstack
   ./tools/discover_hosts.sh
   ```

4. **サービス確認**:
   ```bash
   # コントローラーノードで実行
   source ~/devstack/openrc admin admin
   openstack compute service list
   openstack network agent list
   ```

## デプロイ後のアクセス

### Horizon Dashboard
- URL: `http://<CONTROLLER_IP>/`
- ユーザー名: `admin`
- パスワード: 設定したパスワード（デフォルト: `OpenStack123`）

### CLI アクセス
```bash
# コントローラーノードで
sudo -u stack bash
source ~/devstack/openrc admin admin
openstack server list
```

## トラブルシューティング

### ログファイル
- コントローラー: `/var/log/openstack-deploy.log`
- コンピュート: `/var/log/openstack-compute-deploy.log`
- DevStack: `~/devstack/logs/stack.sh.log`

### よくある問題

1. **メモリ不足**:
   - 最低4GB RAM（推奨8GB）が必要
   - スワップを有効にすることを検討

2. **ネットワーク接続エラー**:
   - インターネット接続を確認
   - ファイアウォール設定を確認
   - DNS設定を確認

3. **権限エラー**:
   - スクリプトをsudoで実行していることを確認
   - stack ユーザーの権限を確認

4. **サービス起動失敗**:
   - `~/devstack/logs/` のログを確認
   - システムリソース（CPU、メモリ、ディスク）を確認

### 再インストール

DevStackを再インストールする場合：

```bash
# stackユーザーとして
cd ~/devstack
./unstack.sh
./clean.sh
./stack.sh
```

### サービス管理

```bash
# サービス停止
sudo -u stack ~/devstack/unstack.sh

# サービス開始
sudo -u stack ~/devstack/stack.sh

# サービス再起動
sudo -u stack bash -c "cd ~/devstack && ./unstack.sh && ./stack.sh"
```

## セキュリティ注意事項

- 本番環境では強力なパスワードを設定してください
- ファイアウォール設定を適切に行ってください
- 定期的にセキュリティアップデートを適用してください
- 不要なサービスを無効にしてください

## サポートされる環境

- **OS**: Ubuntu 20.04 LTS, 22.04 LTS
- **アーキテクチャ**: x86_64, aarch64 (ARM64)
- **仮想化**: KVM, QEMU
- **ネットワーク**: Neutron with OVS

## ライセンス

このプロジェクトはMITライセンスの下で公開されています。