#!/usr/bin/env bash
# OpenStack DevStack Compute Node Auto-Deployment Script
# Supports Ubuntu 20.04+ and multi-architecture (x86_64/aarch64)
# Usage: sudo bash deploy_compute.sh --controller CONTROLLER_IP [OPTIONS]

set -euo pipefail

# ============================================================================
# Configuration and Argument Parsing
# ============================================================================

# Default values
CONTROLLER_IP=""
ADMIN_PASS="OpenStack123"
DEVSTACK_BRANCH="master"
PUBLIC_IF=""
LOG_FILE="/var/log/openstack-compute-deploy.log"
STACK_USER="stack"
STACK_HOME="/opt/stack"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --controller)
            CONTROLLER_IP="$2"
            shift 2
            ;;
        --password)
            ADMIN_PASS="$2"
            shift 2
            ;;
        --branch)
            DEVSTACK_BRANCH="$2"
            shift 2
            ;;
        --public-if)
            PUBLIC_IF="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 --controller CONTROLLER_IP [OPTIONS]"
            echo "Required:"
            echo "  --controller IP    Controller node IP address"
            echo "Options:"
            echo "  --password PASS    Admin password (default: OpenStack123)"
            echo "  --branch BRANCH    DevStack branch (default: master)"
            echo "  --public-if IF     Public interface name (optional)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$CONTROLLER_IP" ]]; then
    echo "ERROR: --controller CONTROLLER_IP is required"
    echo "Use --help for usage information"
    exit 1
fi

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
    
    # Check controller connectivity
    log "Testing connectivity to controller: $CONTROLLER_IP"
    if ! ping -c 3 -W 5 "$CONTROLLER_IP" >/dev/null 2>&1; then
        warning "Cannot ping controller at $CONTROLLER_IP. Network connectivity may be an issue."
    fi
    
    # Check minimum memory (4GB recommended for compute)
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        warning "Less than 2GB RAM detected. Compute node may not work properly."
    fi
    
    # Check disk space (minimum 10GB)
    local disk_gb=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    if [[ $disk_gb -lt 10 ]]; then
        warning "Less than 10GB free disk space. Installation may fail."
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
        lsb-release \
        software-properties-common \
        apt-transport-https \
        ca-certificates \
        cpu-checker \
        qemu-kvm \
        libvirt-daemon \
        libvirt-clients \
        bridge-utils \
        || error "Failed to install essential packages"
    
    log "System packages updated successfully"
}

# ============================================================================
# Architecture and Virtualization Detection
# ============================================================================

detect_architecture() {
    log "Detecting system architecture and virtualization support..."
    
    ARCH=$(dpkg --print-architecture)
    log "Architecture: $ARCH"
    
    # Check for KVM support
    LIBVIRT_TYPE="qemu"
    if [[ -e /dev/kvm ]]; then
        if kvm-ok >/dev/null 2>&1 || [[ $ARCH == "arm64" ]]; then
            LIBVIRT_TYPE="kvm"
            log "KVM virtualization available"
        else
            log "KVM device present but not functional, using QEMU"
        fi
    else
        log "No KVM support detected, using QEMU emulation"
    fi
    
    log "Virtualization type: $LIBVIRT_TYPE"
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
    
    HOST_NAME=$(hostname -s)
    
    log "Network detected: Interface=$DEFAULT_IF, IP=$HOST_IP"
    log "Controller IP: $CONTROLLER_IP"
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
    log "Installing DevStack for compute node..."
    
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

# Create compute node local.conf
log "Creating compute node local.conf..."
cat > local.conf <<LOCALCONF
[[local|localrc]]
# Administrative passwords
ADMIN_PASSWORD=$ADMIN_PASS
DATABASE_PASSWORD=$ADMIN_PASS
RABBIT_PASSWORD=$ADMIN_PASS
SERVICE_PASSWORD=$ADMIN_PASS

# This is a compute node
HOST_IP=$HOST_IP
SERVICE_HOST=$CONTROLLER_IP
MYSQL_HOST=\$SERVICE_HOST
RABBIT_HOST=\$SERVICE_HOST
GLANCE_HOSTPORT=\$SERVICE_HOST:9292
KEYSTONE_AUTH_HOST=\$SERVICE_HOST
KEYSTONE_SERVICE_HOST=\$SERVICE_HOST

# VNC configuration
NOVA_VNC_ENABLED=True
NOVNCPROXY_URL="http://\$SERVICE_HOST:6080/vnc_lite.html"
VNCSERVER_LISTEN=\$HOST_IP
VNCSERVER_PROXYCLIENT_ADDRESS=\$HOST_IP

# Virtualization type
LIBVIRT_TYPE=$LIBVIRT_TYPE

# Only enable compute services on this node
ENABLED_SERVICES=n-cpu,q-agt,placement-client

# Disable services that should only run on controller
disable_service mysql
disable_service rabbit
disable_service key
disable_service horizon
disable_service g-api
disable_service g-reg
disable_service n-api
disable_service n-crt
disable_service n-obj
disable_service n-cond
disable_service n-sch
disable_service n-novnc
disable_service placement-api
disable_service q-svc
disable_service q-dhcp
disable_service q-l3
disable_service q-meta
disable_service cinder
disable_service c-api
disable_service c-vol
disable_service c-sch

# Networking
Q_AGENT=ovs

# Logging
LOGFILE=\$DEST/logs/stack.sh.log
VERBOSE=True
LOG_COLOR=True
SCREEN_LOGDIR=\$DEST/logs

# Optional: Configure public interface if specified
LOCALCONF

if [[ -n "$PUBLIC_IF" ]]; then
    echo "PUBLIC_INTERFACE=$PUBLIC_IF" >> local.conf
fi

log "Generated compute node local.conf:"
grep -v "PASSWORD" local.conf

# Check if DevStack is already running
if [[ -f "\$HOME/.stack-status" ]] || pgrep -f "stack.sh" >/dev/null; then
    log "DevStack appears to be running. Stopping existing services..."
    ./unstack.sh || true
    ./clean.sh || true
    sleep 5
fi

# Run DevStack
log "Starting DevStack compute node installation (this will take 10-20 minutes)..."
if ! ./stack.sh; then
    log "DevStack installation failed. Check logs in \$HOME/devstack/logs/"
    exit 1
fi

# Mark installation as complete
touch "\$HOME/.stack-status"
log "DevStack compute node installation completed successfully"
EOF

    if [[ $? -ne 0 ]]; then
        error "DevStack installation failed"
    fi
    
    log "DevStack compute node installation completed"
}

# ============================================================================
# Post-Installation Verification
# ============================================================================

post_install_verification() {
    log "Running post-installation verification..."
    
    # Check if nova-compute service is running
    if ! systemctl is-active --quiet nova-compute 2>/dev/null && ! pgrep -f "nova-compute" >/dev/null; then
        warning "Nova-compute service may not be running properly"
    else
        log "Nova-compute service is running"
    fi
    
    # Check if OVS agent is running
    if ! pgrep -f "neutron-openvswitch-agent" >/dev/null; then
        warning "Neutron OVS agent may not be running properly"
    else
        log "Neutron OVS agent is running"
    fi
    
    log "Post-installation verification completed"
}

# ============================================================================
# Main Installation Process
# ============================================================================

main() {
    log "Starting OpenStack DevStack Compute Node deployment"
    log "Configuration: Controller=$CONTROLLER_IP, Password=$ADMIN_PASS, Branch=$DEVSTACK_BRANCH"
    
    check_prerequisites
    update_system
    detect_architecture
    detect_network
    setup_stack_user
    install_devstack
    post_install_verification
    
    log "====================================================="
    log "OpenStack DevStack Compute Node deployment completed!"
    log "====================================================="
    log "Compute Node IP: $HOST_IP"
    log "Controller IP: $CONTROLLER_IP"
    log "Virtualization: $LIBVIRT_TYPE"
    log "Log file: $LOG_FILE"
    log "====================================================="
    log "Next steps:"
    log "1. On the CONTROLLER node, run as stack user:"
    log "   cd ~/devstack && ./tools/discover_hosts.sh"
    log "2. Verify compute service registration:"
    log "   source ~/devstack/openrc admin admin"
    log "   openstack compute service list --service nova-compute"
    log "====================================================="
}

# Run main function
main "$@"
