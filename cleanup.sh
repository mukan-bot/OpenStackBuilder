#!/usr/bin/env bash
# OpenStack DevStack Cleanup Script
# Safely removes DevStack installation and cleans up the system

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

STACK_USER="stack"
STACK_HOME="/opt/stack"
FORCE_CLEANUP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_CLEANUP=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--force]"
            echo "  --force    Skip confirmation prompts"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Logging functions
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

# Confirmation function
confirm() {
    if [[ "$FORCE_CLEANUP" == "true" ]]; then
        return 0
    fi
    
    local message="$1"
    echo -n "$message (y/N): "
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if running as root
check_root() {
    if [[ $(id -u) -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Stop DevStack services
stop_devstack() {
    log_info "Stopping DevStack services..."
    
    if [[ -d "$STACK_HOME/devstack" ]]; then
        sudo -u "$STACK_USER" bash -c "cd $STACK_HOME/devstack && ./unstack.sh" || true
        log_success "DevStack services stopped"
    else
        log_warning "DevStack directory not found"
    fi
}

# Clean DevStack
clean_devstack() {
    log_info "Cleaning DevStack installation..."
    
    if [[ -d "$STACK_HOME/devstack" ]]; then
        sudo -u "$STACK_USER" bash -c "cd $STACK_HOME/devstack && ./clean.sh" || true
        log_success "DevStack cleaned"
    fi
}

# Remove DevStack files
remove_devstack_files() {
    if confirm "Remove DevStack source code and configuration?"; then
        log_info "Removing DevStack files..."
        
        if [[ -d "$STACK_HOME" ]]; then
            rm -rf "$STACK_HOME/devstack" || true
            rm -rf "$STACK_HOME/logs" || true
            rm -rf "$STACK_HOME/data" || true
            rm -rf "$STACK_HOME/."* || true
            log_success "DevStack files removed"
        fi
    fi
}

# Remove stack user
remove_stack_user() {
    if confirm "Remove stack user account?"; then
        log_info "Removing stack user..."
        
        # Kill any processes owned by stack user
        pkill -u "$STACK_USER" || true
        sleep 2
        pkill -9 -u "$STACK_USER" || true
        
        # Remove user
        if id -u "$STACK_USER" >/dev/null 2>&1; then
            userdel -r "$STACK_USER" || true
            log_success "Stack user removed"
        else
            log_warning "Stack user not found"
        fi
        
        # Remove sudoers file
        if [[ -f "/etc/sudoers.d/stack" ]]; then
            rm -f "/etc/sudoers.d/stack"
            log_success "Stack sudoers file removed"
        fi
    fi
}

# Clean network configuration
clean_network() {
    if confirm "Clean network bridges and interfaces?"; then
        log_info "Cleaning network configuration..."
        
        # Remove OVS bridges
        for bridge in br-ex br-int br-tun; do
            if ip link show "$bridge" >/dev/null 2>&1; then
                ip link delete "$bridge" || true
                log_info "Removed bridge: $bridge"
            fi
        done
        
        # Clean iptables rules (be careful!)
        if confirm "Reset iptables rules? (WARNING: This will remove ALL iptables rules)"; then
            iptables -F || true
            iptables -X || true
            iptables -t nat -F || true
            iptables -t nat -X || true
            iptables -t mangle -F || true
            iptables -t mangle -X || true
            log_warning "Iptables rules reset"
        fi
        
        log_success "Network cleanup completed"
    fi
}

# Clean system packages
clean_packages() {
    if confirm "Remove OpenStack-related packages?"; then
        log_info "Cleaning system packages..."
        
        # List of packages that might have been installed
        local packages=(
            "python3-openstackclient"
            "python3-neutronclient"
            "python3-novaclient"
            "python3-glanceclient"
            "python3-cinderclient"
            "python3-keystoneclient"
            "rabbitmq-server"
            "mysql-server"
            "apache2"
            "memcached"
            "openvswitch-switch"
            "qemu-kvm"
            "libvirt-daemon"
        )
        
        for package in "${packages[@]}"; do
            if dpkg -l | grep -q "^ii.*$package"; then
                log_info "Removing package: $package"
                apt-get remove -y "$package" || true
            fi
        done
        
        # Autoremove unused packages
        apt-get autoremove -y || true
        
        log_success "Package cleanup completed"
    fi
}

# Clean log files
clean_logs() {
    if confirm "Remove OpenStack log files?"; then
        log_info "Cleaning log files..."
        
        # Remove deployment logs
        rm -f "/var/log/openstack-deploy.log" || true
        rm -f "/var/log/openstack-compute-deploy.log" || true
        
        # Clean system logs related to OpenStack
        journalctl --vacuum-time=1d || true
        
        log_success "Log files cleaned"
    fi
}

# Clean temporary files
clean_temp_files() {
    log_info "Cleaning temporary files..."
    
    # Clean pip cache
    pip3 cache purge || true
    
    # Clean apt cache
    apt-get clean || true
    
    # Clean tmp files
    find /tmp -name "*openstack*" -type f -delete || true
    find /tmp -name "*devstack*" -type f -delete || true
    
    log_success "Temporary files cleaned"
}

# Display system status
show_status() {
    log_info "System status after cleanup:"
    
    # Show running services
    log_info "Running OpenStack-related services:"
    systemctl list-units --state=running | grep -E "(nova|neutron|glance|keystone|cinder|rabbit|mysql|apache|memcached)" || echo "None found"
    
    # Show network interfaces
    log_info "Network interfaces:"
    ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/:$//' | grep -v lo
    
    # Show disk usage
    log_info "Disk usage:"
    df -h / | tail -n 1
    
    # Show memory usage
    log_info "Memory usage:"
    free -h | grep Mem
}

# Main cleanup function
main() {
    echo "============================================="
    echo "OpenStack DevStack Cleanup Script"
    echo "Date: $(date)"
    echo "============================================="
    
    if [[ "$FORCE_CLEANUP" == "false" ]]; then
        log_warning "This script will remove DevStack and clean up the system."
        log_warning "Make sure you have backed up any important data."
        if ! confirm "Continue with cleanup?"; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi
    
    check_root
    stop_devstack
    clean_devstack
    remove_devstack_files
    remove_stack_user
    clean_network
    clean_packages
    clean_logs
    clean_temp_files
    show_status
    
    echo "============================================="
    log_success "Cleanup completed successfully!"
    log_info "You may want to reboot the system to ensure all changes take effect."
    echo "============================================="
}

# Run main function
main "$@"