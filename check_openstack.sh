#!/usr/bin/env bash
# OpenStack Status Check Script

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   OpenStack DevStack Status Check     ${NC}"
echo -e "${GREEN}========================================${NC}"
echo

# Check if running as stack user
if [[ $(whoami) != "stack" ]]; then
    echo -e "${YELLOW}Switching to stack user...${NC}"
    sudo -u stack "$0"
    exit $?
fi

# Source credentials
cd ~/devstack
source openrc admin admin

echo -e "${BLUE}🌐 Dashboard Access:${NC}"
echo -e "   URL: ${YELLOW}http://$(hostname -I | awk '{print $1}')/dashboard${NC}"
echo -e "   Username: ${YELLOW}admin${NC}"
echo -e "   Password: ${YELLOW}OpenStack123${NC}"
echo

echo -e "${BLUE}🔐 Keystone Identity Service:${NC}"
echo -e "   URL: ${YELLOW}http://$(hostname -I | awk '{print $1}')/identity${NC}"
echo

echo -e "${BLUE}⚙️  OpenStack Services Status:${NC}"
openstack catalog list 2>/dev/null || echo "   Services are starting up..."
echo

echo -e "${BLUE}🖥️  Compute Services:${NC}"
openstack compute service list 2>/dev/null || echo "   Compute services are starting up..."
echo

echo -e "${BLUE}🌐 Network Services:${NC}"
openstack network agent list 2>/dev/null || echo "   Network services are starting up..."
echo

echo -e "${BLUE}💾 Volume Services:${NC}"
openstack volume service list 2>/dev/null || echo "   Volume services are starting up..."
echo

echo -e "${BLUE}📋 Projects:${NC}"
openstack project list 2>/dev/null || echo "   Projects are being initialized..."
echo

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   OpenStack is ready for use!         ${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo -e "${YELLOW}💡 Quick Commands:${NC}"
echo -e "   • Check status: ${BLUE}sudo -u stack ~/devstack/tools/info.sh${NC}"
echo -e "   • Stop services: ${BLUE}sudo -u stack ~/devstack/unstack.sh${NC}"
echo -e "   • Start services: ${BLUE}sudo -u stack ~/devstack/stack.sh${NC}"
echo -e "   • View logs: ${BLUE}sudo -u stack tail -f ~/devstack/logs/stack.sh.log${NC}"