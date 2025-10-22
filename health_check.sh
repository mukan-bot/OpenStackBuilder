#!/usr/bin/env bash
# OpenStack Health Check Script
# Checks the status of OpenStack services and provides troubleshooting information

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NODE_TYPE="controller"
CONTROLLER_IP=""
STACK_USER="stack"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            NODE_TYPE="$2"
            shift 2
            ;;
        --controller)
            CONTROLLER_IP="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--type controller|compute] [--controller IP]"
            echo "  --type TYPE        Node type: controller or compute (default: controller)"
            echo "  --controller IP    Controller IP (required for compute nodes)"
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

# Check if running as stack user
check_user() {
    if [[ "$(whoami)" != "$STACK_USER" ]]; then
        log_error "This script should be run as the stack user"
        log_info "Switch to stack user: sudo -u stack bash"
        exit 1
    fi
}

# Check DevStack installation
check_devstack() {
    log_info "Checking DevStack installation..."
    
    if [[ ! -d "$HOME/devstack" ]]; then
        log_error "DevStack directory not found at $HOME/devstack"
        return 1
    fi
    
    if [[ ! -f "$HOME/devstack/local.conf" ]]; then
        log_error "local.conf not found"
        return 1
    fi
    
    if [[ ! -f "$HOME/devstack/openrc" ]]; then
        log_error "openrc file not found"
        return 1
    fi
    
    log_success "DevStack installation found"
    return 0
}

# Source OpenStack credentials
source_credentials() {
    log_info "Sourcing OpenStack credentials..."
    
    if ! source "$HOME/devstack/openrc" admin admin 2>/dev/null; then
        log_error "Failed to source OpenStack credentials"
        return 1
    fi
    
    log_success "Credentials sourced successfully"
    return 0
}

# Check OpenStack services (controller)
check_controller_services() {
    log_info "Checking OpenStack services on controller..."
    
    # Check keystone
    if openstack token issue >/dev/null 2>&1; then
        log_success "Keystone is working"
    else
        log_error "Keystone is not responding"
    fi
    
    # Check nova
    if openstack compute service list >/dev/null 2>&1; then
        log_success "Nova API is working"
        openstack compute service list
    else
        log_error "Nova API is not responding"
    fi
    
    # Check glance
    if openstack image list >/dev/null 2>&1; then
        log_success "Glance is working"
    else
        log_error "Glance is not responding"
    fi
    
    # Check neutron
    if openstack network list >/dev/null 2>&1; then
        log_success "Neutron is working"
        openstack network agent list
    else
        log_error "Neutron is not responding"
    fi
    
    # Check cinder
    if openstack volume service list >/dev/null 2>&1; then
        log_success "Cinder is working"
    else
        log_warning "Cinder may not be enabled or working"
    fi
}

# Check compute services
check_compute_services() {
    log_info "Checking compute node services..."
    
    # Check if nova-compute is running
    if pgrep -f "nova-compute" >/dev/null; then
        log_success "Nova-compute is running"
    else
        log_error "Nova-compute is not running"
    fi
    
    # Check if neutron agent is running
    if pgrep -f "neutron-openvswitch-agent" >/dev/null; then
        log_success "Neutron OVS agent is running"
    else
        log_error "Neutron OVS agent is not running"
    fi
    
    # Check connectivity to controller
    if [[ -n "$CONTROLLER_IP" ]]; then
        if ping -c 3 "$CONTROLLER_IP" >/dev/null 2>&1; then
            log_success "Can ping controller at $CONTROLLER_IP"
        else
            log_error "Cannot ping controller at $CONTROLLER_IP"
        fi
    fi
}

# Check system resources
check_system_resources() {
    log_info "Checking system resources..."
    
    # Memory
    local mem_total=$(free -g | awk '/^Mem:/{print $2}')
    local mem_used=$(free -g | awk '/^Mem:/{print $3}')
    local mem_percent=$((mem_used * 100 / mem_total))
    
    if [[ $mem_percent -lt 80 ]]; then
        log_success "Memory usage: ${mem_used}GB/${mem_total}GB (${mem_percent}%)"
    else
        log_warning "High memory usage: ${mem_used}GB/${mem_total}GB (${mem_percent}%)"
    fi
    
    # Disk
    local disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
    if [[ $disk_usage -lt 80 ]]; then
        log_success "Disk usage: ${disk_usage}%"
    else
        log_warning "High disk usage: ${disk_usage}%"
    fi
    
    # Load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    local cpu_count=$(nproc)
    if (( $(echo "$load_avg < $cpu_count" | bc -l) )); then
        log_success "Load average: $load_avg (CPUs: $cpu_count)"
    else
        log_warning "High load average: $load_avg (CPUs: $cpu_count)"
    fi
}

# Check network connectivity
check_network() {
    log_info "Checking network configuration..."
    
    # Check interfaces
    local interfaces=$(ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo)
    log_info "Network interfaces: $interfaces"
    
    # Check if br-ex exists (external bridge)
    if ip link show br-ex >/dev/null 2>&1; then
        log_success "External bridge (br-ex) exists"
    else
        log_warning "External bridge (br-ex) not found"
    fi
    
    # Check if br-int exists (integration bridge)
    if ip link show br-int >/dev/null 2>&1; then
        log_success "Integration bridge (br-int) exists"
    else
        log_warning "Integration bridge (br-int) not found"
    fi
}

# Check log files for errors
check_logs() {
    log_info "Checking recent log entries for errors..."
    
    local log_dir="$HOME/devstack/logs"
    if [[ -d "$log_dir" ]]; then
        local error_count=$(find "$log_dir" -name "*.log" -exec grep -l "ERROR\|CRITICAL" {} \; 2>/dev/null | wc -l)
        if [[ $error_count -eq 0 ]]; then
            log_success "No recent errors found in logs"
        else
            log_warning "$error_count log files contain errors"
            log_info "Check logs in: $log_dir"
        fi
    else
        log_warning "Log directory not found: $log_dir"
    fi
}

# Main health check function
main() {
    echo "=============================================="
    echo "OpenStack DevStack Health Check"
    echo "Node Type: $NODE_TYPE"
    echo "Date: $(date)"
    echo "=============================================="
    
    # Basic checks
    check_user
    check_devstack
    check_system_resources
    check_network
    
    if [[ "$NODE_TYPE" == "controller" ]]; then
        source_credentials
        check_controller_services
    elif [[ "$NODE_TYPE" == "compute" ]]; then
        check_compute_services
        if [[ -n "$CONTROLLER_IP" ]]; then
            log_info "Controller IP: $CONTROLLER_IP"
        fi
    fi
    
    check_logs
    
    echo "=============================================="
    echo "Health check completed"
    echo "=============================================="
}

# Run main function
main "$@"