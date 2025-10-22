#!/usr/bin/env bash
# OpenStack DevStack Controller Node Auto-Deployment Script
# Supports Ubuntu 20.04+
# Usage: sudo bash deploy_controller.sh [--password PASSWORD] [--branch BRANCH]

set -euo pipefail

# ============================================================================
# Configuration and Argument Parsing
# ============================================================================

# Default values
ADMIN_PASS="OpenStack123"
DEVSTACK_BRANCH="master"
LOG_FILE="/var/log/openstack-deploy.log"
STACK_USER="stack"
STACK_HOME="/opt/stack"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --password)
            ADMIN_PASS="$2"
            shift 2
            ;;
        --branch)
            DEVSTACK_BRANCH="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--password PASSWORD] [--branch BRANCH]"
            echo "  --password PASSWORD  Set admin password (default: OpenStack123)"
            echo "  --branch BRANCH      DevStack branch (default: master)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ============================================================================
# Logging and Error Handling
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

warning() {
    log "WARNING: $*" >&2
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log "Script failed with exit code $exit_code"
        log "Check log file: $LOG_FILE"
    fi
}
trap cleanup EXIT

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if running as root
    if [[ $(id -u) -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
    
    # Check Ubuntu version
    if ! lsb_release -d 2>/dev/null | grep -q "Ubuntu"; then
        warning "This script is designed for Ubuntu. Proceeding anyway..."
    fi
    
    # Check minimum memory (8GB recommended)
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        warning "Less than 2GB RAM detected ($mem_gb GB). OpenStack may not work properly."
        warning "Consider adding more memory or using a smaller configuration."
    elif [[ $mem_gb -lt 4 ]]; then
        warning "Less than 4GB RAM detected ($mem_gb GB). Performance may be limited."
    fi
    
    # Check disk space (minimum 20GB)
    local disk_gb=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    if [[ $disk_gb -lt 20 ]]; then
        warning "Less than 20GB free disk space. Installation may fail."
    fi
    
    log "Prerequisites check completed"
}

# ============================================================================
# System Preparation
# ============================================================================

update_system() {
    log "Updating system packages..."
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || error "Failed to update package list"
    
    # Install essential packages
    apt-get install -y \
        git \
        python3-pip \
        python3-dev \
        build-essential \
        libssl-dev \
        libffi-dev \
        net-tools \
        curl \
        wget \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        lsb-release \
        || error "Failed to install essential packages"
    
    log "System packages updated successfully"
}

# ============================================================================
# Network Configuration Detection
# ============================================================================

detect_network() {
    log "Detecting network configuration..."
    
    # Get primary interface and IP
    DEFAULT_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
    if [[ -z "$DEFAULT_IF" ]]; then
        error "Could not detect primary network interface"
    fi
    
    HOST_IP=$(ip -4 addr show dev "$DEFAULT_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
    if [[ -z "$HOST_IP" ]]; then
        error "Could not detect host IP address"
    fi
    
    GATEWAY_IP=$(ip -o -4 route show to default | awk '{print $3}' | head -n1)
    HOST_NAME=$(hostname -s)
    
    log "Network detected: Interface=$DEFAULT_IF, IP=$HOST_IP, Gateway=$GATEWAY_IP"
}

# ============================================================================
# User Management
# ============================================================================

setup_stack_user() {
    log "Setting up stack user..."
    
    # Create stack user if it doesn't exist
    if ! id -u "$STACK_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -d "$STACK_HOME" "$STACK_USER" || error "Failed to create stack user"
        log "Created stack user"
    else
        log "Stack user already exists"
    fi
    
    # Set proper permissions
    chmod 755 "$STACK_HOME" || error "Failed to set stack home permissions"
    
    # Configure sudo access
    echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/stack || error "Failed to configure sudo for stack user"
    
    log "Stack user setup completed"
}

# ============================================================================
# DevStack Installation
# ============================================================================

install_devstack() {
    log "Installing DevStack..."
    
    sudo -i -u "$STACK_USER" bash <<EOF
set -euo pipefail

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*"
}

# Clone or update DevStack
DEVSTACK_DIR="\$HOME/devstack"
if [[ ! -d "\$DEVSTACK_DIR" ]]; then
    log "Cloning DevStack repository..."
    git clone https://opendev.org/openstack/devstack "\$DEVSTACK_DIR" || exit 1
else
    log "DevStack already exists, updating..."
    cd "\$DEVSTACK_DIR"
    
    # Backup existing local.conf
    if [[ -f "local.conf" ]]; then
        cp local.conf "local.conf.backup.\$(date +%Y%m%d_%H%M%S)"
        log "Backed up existing local.conf"
    fi
    
    # Clean and update
    git stash || true
    git checkout "$DEVSTACK_BRANCH" || git checkout master || true
    git pull origin "$DEVSTACK_BRANCH" || git pull origin master || true
fi

cd "\$DEVSTACK_DIR"

# Create local.conf
log "Creating local.conf..."
cat > local.conf <<'LOCALCONF'
[[local|localrc]]
# Administrative passwords
ADMIN_PASSWORD=ADMIN_PASS_PLACEHOLDER
DATABASE_PASSWORD=ADMIN_PASS_PLACEHOLDER
RABBIT_PASSWORD=ADMIN_PASS_PLACEHOLDER
SERVICE_PASSWORD=ADMIN_PASS_PLACEHOLDER

# Network configuration
HOST_IP=HOST_IP_PLACEHOLDER
SERVICE_HOST=HOST_IP_PLACEHOLDER

# DevStack directories
DEST=/opt/stack
DATA_DIR=\$DEST/data
SERVICE_DIR=\$DEST/status

# Force OVS instead of OVN
Q_AGENT=openvswitch
Q_ML2_TENANT_NETWORK_TYPE=vxlan
NEUTRON_AGENT=openvswitch
USE_OVN=False
OVN_BUILD_FROM_SOURCE=False

# Enable core services
enable_service mysql
enable_service rabbit
enable_service key

# Enable Nova services
enable_service n-api
enable_service n-cpu
enable_service n-cond
enable_service n-sch
enable_service n-novnc
enable_service placement-api
enable_service placement-client

# Enable Glance
enable_service g-api
enable_service g-reg

# Enable Neutron with OVS (not OVN) - MUST come before any disable statements
enable_service q-svc
enable_service q-agt
enable_service q-dhcp
enable_service q-l3
enable_service q-meta

# Enable Horizon
enable_service horizon

# Enable Cinder
enable_service cinder
enable_service c-api
enable_service c-vol
enable_service c-sch

# Explicitly disable ALL OVN services
disable_service ovn-controller
disable_service ovn-northd
disable_service ovs-vswitchd
disable_service ovsdb-server
disable_service q-ovn-metadata-agent

# Logging
LOGFILE=\$DEST/logs/stack.sh.log
VERBOSE=True
LOG_COLOR=True
SCREEN_LOGDIR=\$DEST/logs

# Floating IP configuration
FLOATING_RANGE=172.24.4.0/24
PUBLIC_NETWORK_GATEWAY=172.24.4.1
Q_FLOATING_ALLOCATION_POOL=start=172.24.4.225,end=172.24.4.254

# Fixed IP configuration
FIXED_RANGE=10.4.128.0/20
NETWORK_GATEWAY=10.4.128.1

# Neutron ML2 configuration
Q_PLUGIN=ml2
Q_ML2_PLUGIN_MECHANISM_DRIVERS=openvswitch
Q_ML2_PLUGIN_TYPE_DRIVERS=vxlan,flat,vlan
ENABLE_TENANT_VLANS=True

# Completely disable OVN
USE_OVN=False
Q_USE_OVN=False
NEUTRON_USE_OVN=False

# Swift (optional - disable for faster deployment)
disable_service s-proxy s-object s-container s-account

# Tempest (optional - disable for faster deployment)
disable_service tempest
LOCALCONF

# Replace placeholders with actual values
sed -i "s/ADMIN_PASS_PLACEHOLDER/$ADMIN_PASS/g" local.conf
sed -i "s/HOST_IP_PLACEHOLDER/$HOST_IP/g" local.conf

log "Generated local.conf:"
grep -v "PASSWORD" local.conf

# Check if DevStack is already running
if [[ -f "\$HOME/.stack-status" ]] || pgrep -f "stack.sh" >/dev/null; then
    log "DevStack appears to be running. Stopping existing services..."
    ./unstack.sh || true
    ./clean.sh || true
    sleep 5
fi

# Clean any existing OVN configuration
log "Cleaning any existing OVN configuration..."
sudo systemctl stop ovn-controller || true
sudo systemctl stop ovn-northd || true
sudo systemctl disable ovn-controller || true
sudo systemctl disable ovn-northd || true
sudo apt-get remove -y ovn-central ovn-common ovn-host || true

# Run DevStack
log "Starting DevStack installation (this will take 15-30 minutes)..."
if ! ./stack.sh; then
    log "DevStack installation failed. Check logs in \$HOME/devstack/logs/"
    exit 1
fi

# Mark installation as complete
touch "\$HOME/.stack-status"
log "DevStack installation completed successfully"
EOF

    if [[ $? -ne 0 ]]; then
        error "DevStack installation failed"
    fi
    
    log "DevStack installation completed"
}

# ============================================================================
# Post-Installation Configuration
# ============================================================================

post_install_config() {
    log "Running post-installation configuration..."
    
    sudo -i -u "$STACK_USER" bash <<EOF
set -euo pipefail

# Source OpenStack credentials
source \$HOME/devstack/openrc admin admin

# Wait for services to be ready
echo "Waiting for OpenStack services to be ready..."
sleep 30

# Create default security group rules
echo "Configuring default security group..."
openstack security group rule create --proto icmp default || true
openstack security group rule create --proto tcp --dst-port 22 default || true
openstack security group rule create --proto tcp --dst-port 80 default || true
openstack security group rule create --proto tcp --dst-port 443 default || true

echo "Security group rules created"
EOF

    log "Post-installation configuration completed"
}

# ============================================================================
# Main Installation Process
# ============================================================================

main() {
    log "Starting OpenStack DevStack Controller deployment"
    log "Configuration: Password=${ADMIN_PASS}, Branch=${DEVSTACK_BRANCH}"
    log "Command line arguments: $*"
    
    check_prerequisites
    update_system
    detect_network
    setup_stack_user
    install_devstack
    post_install_config
    
    log "====================================================="
    log "OpenStack DevStack Controller deployment completed!"
    log "====================================================="
    log "Dashboard URL: http://$HOST_IP/"
    log "Username: admin"
    log "Password: $ADMIN_PASS"
    log "Log file: $LOG_FILE"
    log "====================================================="
    
    # Display service status
    sudo -i -u "$STACK_USER" bash -c "source ~/devstack/openrc admin admin && openstack service list" || true
}

# Run main function
main "$@"

