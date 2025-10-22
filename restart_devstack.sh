#!/usr/bin/env bash
# DevStack Quick Cleanup and Restart Script
# Use this when you need to quickly clean and restart DevStack

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

# Check if running as stack user
if [[ "$(whoami)" != "stack" ]]; then
    log_error "This script should be run as the stack user"
    log_info "Switch to stack user: sudo -u stack bash"
    exit 1
fi

# Change to devstack directory
cd ~/devstack || {
    log_error "DevStack directory not found at ~/devstack"
    exit 1
}

log_info "Starting DevStack cleanup and restart..."

# Stop existing services
log_info "Stopping existing DevStack services..."
if [[ -f "./unstack.sh" ]]; then
    ./unstack.sh || true
    log_success "DevStack services stopped"
else
    log_warning "unstack.sh not found"
fi

# Clean existing installation
log_info "Cleaning existing DevStack installation..."
if [[ -f "./clean.sh" ]]; then
    ./clean.sh || true
    log_success "DevStack cleaned"
else
    log_warning "clean.sh not found"
fi

# Remove status files
log_info "Removing status files..."
rm -f ~/.stack-status || true
rm -rf /opt/stack/status/ || true

# Wait a moment
log_info "Waiting for cleanup to complete..."
sleep 5

# Restart DevStack
log_info "Starting DevStack installation..."
if [[ -f "./stack.sh" ]]; then
    ./stack.sh
    if [[ $? -eq 0 ]]; then
        log_success "DevStack installation completed successfully!"
        log_info "Dashboard URL: http://$(hostname -I | awk '{print $1}')/"
        log_info "Username: admin"
        log_info "Check local.conf for password"
    else
        log_error "DevStack installation failed"
        log_info "Check logs in ~/devstack/logs/ for details"
        exit 1
    fi
else
    log_error "stack.sh not found in ~/devstack"
    exit 1
fi

log_success "DevStack restart completed!"