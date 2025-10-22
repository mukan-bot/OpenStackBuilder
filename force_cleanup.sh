#!/usr/bin/env bash
# Complete DevStack Cleanup for OVN Issues
# This script completely removes DevStack and any OVN components

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if running as root
if [[ $(id -u) -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "Starting complete DevStack and OVN cleanup..."

# Stop all DevStack services as stack user
log_info "Stopping DevStack services..."
if id -u stack >/dev/null 2>&1; then
    sudo -u stack bash -c "
        cd /opt/stack/devstack 2>/dev/null || true
        ./unstack.sh 2>/dev/null || true
        ./clean.sh 2>/dev/null || true
    " || true
fi

# Stop and disable OVN services
log_info "Stopping OVN services..."
systemctl stop ovn-controller 2>/dev/null || true
systemctl stop ovn-northd 2>/dev/null || true
systemctl stop ovn-central 2>/dev/null || true
systemctl disable ovn-controller 2>/dev/null || true
systemctl disable ovn-northd 2>/dev/null || true
systemctl disable ovn-central 2>/dev/null || true

# Remove OVN packages
log_info "Removing OVN packages..."
apt-get remove -y ovn-central ovn-common ovn-host ovn-docker 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Clean up OpenStack Python packages
log_info "Cleaning up OpenStack Python packages..."
if [[ -d "/opt/stack/data/venv" ]]; then
    rm -rf /opt/stack/data/venv
fi

# Remove all OVS bridges
log_info "Cleaning up OVS bridges..."
for bridge in br-ex br-int br-tun; do
    if ip link show "$bridge" >/dev/null 2>&1; then
        ip link delete "$bridge" 2>/dev/null || true
        log_info "Removed bridge: $bridge"
    fi
done

# Clean up DevStack status and logs
log_info "Cleaning up DevStack files..."
rm -rf /opt/stack/status 2>/dev/null || true
rm -rf /opt/stack/logs 2>/dev/null || true
rm -rf /opt/stack/data 2>/dev/null || true
sudo -u stack rm -f /opt/stack/.stack-status 2>/dev/null || true

# Reset iptables rules (optional but recommended)
log_warning "Resetting iptables rules..."
iptables -F || true
iptables -X || true
iptables -t nat -F || true
iptables -t nat -X || true

# Clean up any remaining OpenStack processes
log_info "Cleaning up remaining OpenStack processes..."
pkill -f "neutron" || true
pkill -f "nova" || true
pkill -f "glance" || true
pkill -f "keystone" || true
pkill -f "cinder" || true

# Wait for cleanup to complete
log_info "Waiting for cleanup to complete..."
sleep 5

log_success "Complete cleanup finished!"
log_info "You can now run the deploy script again:"
log_info "sudo ./deploy_controller.sh --password YourPassword"