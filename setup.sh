#!/usr/bin/env bash
# OpenStack DevStack Deployment Scripts Setup
# Sets executable permissions and validates scripts for Linux deployment

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
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

echo "=============================================="
echo "OpenStack DevStack Scripts Setup"
echo "=============================================="

# List of shell scripts to process
SCRIPTS=(
    "deploy_controller.sh"
    "deploy_compute.sh" 
    "health_check.sh"
    "cleanup.sh"
)

log_info "Setting executable permissions on shell scripts..."

# Set executable permissions
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        chmod +x "$script"
        log_success "Set executable permission: $script"
    else
        log_warning "Script not found: $script"
    fi
done

echo ""
log_info "Validating script syntax..."

# Validate bash syntax
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        if bash -n "$script" 2>/dev/null; then
            log_success "Syntax OK: $script"
        else
            log_warning "Syntax error in: $script"
        fi
    fi
done

echo ""
log_info "Current script permissions:"
ls -la *.sh 2>/dev/null || echo "No shell scripts found"

echo ""
echo "=============================================="
log_success "Setup completed!"
echo "=============================================="
echo ""
echo "Quick Start Guide:"
echo "=================="
echo ""
echo "1. Deploy Controller Node:"
echo "   sudo ./deploy_controller.sh --password YourPassword123"
echo ""
echo "2. Deploy Compute Node(s):"
echo "   sudo ./deploy_compute.sh --controller CONTROLLER_IP --password YourPassword123"
echo ""
echo "3. Check Health:"
echo "   sudo -u stack ./health_check.sh --type controller"
echo "   sudo -u stack ./health_check.sh --type compute --controller CONTROLLER_IP"
echo ""
echo "4. Cleanup (if needed):"
echo "   sudo ./cleanup.sh"
echo ""
echo "For detailed documentation, see: README.md"
echo "=============================================="