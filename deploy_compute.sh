#!/usr/bin/env bash
# DevStack multi-node: Compute node bootstrap for Ubuntu LTS (x86_64 / aarch64)
# - Creates 'stack' user
# - Detects HOST_IP, KVM availability (/dev/kvm)
# - Generates compute-role local.conf pointing to controller
# - Runs ./stack.sh
# Usage:
#   sudo bash deploy_compute.sh --controller <CONTROLLER_IP> [--password <PASS>] [--public-if <IFNAME>]

set -euo pipefail

# ---------- Parse args ----------
CONTROLLER_IP=""
ADMIN_PASS="OpenStack123"
PUBLIC_IF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --controller) CONTROLLER_IP="$2"; shift 2;;
    --password)   ADMIN_PASS="$2"; shift 2;;
    --public-if)  PUBLIC_IF="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [[ -z "${CONTROLLER_IP}" ]]; then
  echo "ERROR: --controller <CONTROLLER_IP> is required (controller's HOST_IP / SERVICE_HOST)."
  exit 1
fi

# ---------- Sanity ----------
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root (sudo)."; exit 1
fi

# ---------- OS prep ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y git python3-pip net-tools lsb-release curl

# ---------- Detect host info ----------
DEFAULT_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)
if [[ -z "${DEFAULT_IF}" ]]; then echo "Cannot find default interface"; exit 1; fi
HOST_IP=$(ip -4 -o addr show dev "$DEFAULT_IF" primary | awk '{print $4}' | cut -d/ -f1)
HOST_NAME=$(hostname -s)

ARCH=$(dpkg --print-architecture)   # amd64 / arm64 など
echo "Compute node arch: ${ARCH}; IF=${DEFAULT_IF}; IP=${HOST_IP}; Controller=${CONTROLLER_IP}"

# ---------- KVM detection (ARM対応) ----------
# aarch64(Raspberry Pi等)でも /dev/kvm があればKVM、無ければQEMUに自動切替
LIBVIRT_TYPE="qemu"
if [[ -e /dev/kvm ]]; then
  LIBVIRT_TYPE="kvm"
fi
echo "LIBVIRT_TYPE=${LIBVIRT_TYPE}"

# ---------- Create stack user ----------
STACK_HOME="/opt/stack"
if ! id -u stack >/dev/null 2>&1; then
  useradd -m -s /bin/bash -d "${STACK_HOME}" stack
  chmod 755 "${STACK_HOME}"   # Ubuntu 21.04+ の権限問題回避（公式ガイドに準拠）
fi
echo "stack ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/stack

# ---------- Clone DevStack ----------
sudo -i -u stack bash <<'EOSU'
set -e
if [[ ! -d ~/devstack ]]; then
  git clone https://opendev.org/openstack/devstack ~/devstack
fi
EOSU

# ---------- Generate compute local.conf ----------
DB_PASS="${ADMIN_PASS}"
RABBIT_PASS="${ADMIN_PASS}"
SERVICE_PASS="${ADMIN_PASS}"

sudo -i -u stack bash <<EOSU
set -e
cd ~/devstack

cat > local.conf <<LOCALCONF
[[local|localrc]]
# --- identity & shared passwords (no prompts) ---
ADMIN_PASSWORD=${ADMIN_PASS}
DATABASE_PASSWORD=${DB_PASS}
RABBIT_PASSWORD=${RABBIT_PASS}
SERVICE_PASSWORD=${SERVICE_PASS}

# --- role: compute node (no API services here) ---
HOST_IP=${HOST_IP}
SERVICE_HOST=${CONTROLLER_IP}
MYSQL_HOST=\$SERVICE_HOST
RABBIT_HOST=\$SERVICE_HOST
GLANCE_HOSTPORT=\$SERVICE_HOST:9292

# VNC: proxy is on controller; compute listens on its own IP
NOVA_VNC_ENABLED=True
NOVNCPROXY_URL="http://\$SERVICE_HOST:6080/vnc_lite.html"
VNCSERVER_LISTEN=\$HOST_IP
VNCSERVER_PROXYCLIENT_ADDRESS=\$VNCSERVER_LISTEN

# Libvirt/KVM auto switch (set above)
LIBVIRT_TYPE=${LIBVIRT_TYPE}

# Enable only worker-side services on compute
# (参考: DevStack Multi-Node 'Configure Compute Nodes')
ENABLED_SERVICES=n-cpu,placement-client,q-agt

# ML2/OVS を使う場合の典型（必要に応じてdriverを追加）
enable_plugin neutron https://opendev.org/openstack/neutron
Q_AGENT=ovs

# Optional logging to controller syslog (uncomment to enable)
#SYSLOG=True
#SYSLOG_HOST=\$SERVICE_HOST

# Networking hints: inherit ranges from controller where applicable
# (FIXED/FLOATING rangeはコントローラ側に合わせる必要がある)
# FIXED_RANGE=10.4.128.0/20
# FLOATING_RANGE=192.168.42.128/25

# For ARM/aarch64 guests: upload ARM64 images (see notes after install)
LOCALCONF

# If PUBLIC_IF was provided, persist for OVS external bridge usage later (optional)
if [[ -n "${PUBLIC_IF}" ]]; then
  echo "# public interface hint" >> local.conf
  echo "PUBLIC_INTERFACE=${PUBLIC_IF}" >> local.conf
fi

echo "=== Generated local.conf (compute) ==="
grep -v PASSWORD local.conf || true
EOSU

# ---------- Run stack.sh on compute ----------
echo "Starting DevStack on compute node (this may take a while)..."
sudo -i -u stack bash -lc "cd ~/devstack && ./stack.sh"

# ---------- Post steps (cells v2 discovery from controller side案内だけ) ----------
cat <<'EOP'
[INFO] Compute node stacked.
Next on the CONTROLLER node (as stack user):
  cd ~/devstack
  ./tools/discover_hosts.sh        # Map this compute into Cells v2
Then verify on controller:
  openstack compute service list --service nova-compute
EOP

echo "[DONE] Compute node setup complete."
