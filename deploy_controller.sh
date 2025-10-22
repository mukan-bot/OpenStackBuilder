#!/usr/bin/env bash
# OpenStack DevStack Auto-Deployment Script for Ubuntu 22.04+

set -e  # exit on any error
set -o pipefail

# 1. Prerequisites and Environment Detection
############################################

# Ensure the script is run as root (or with sudo)
if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run this script as root or with sudo."
    exit 1
fi

echo "Updating system packages and installing prerequisites..."
apt-get update -y
apt-get install -y git python3-pip  # git is needed to fetch DevStack

# (Optional) Upgrade packages and reboot if needed
if apt-get upgrade -y && [ -f /var/run/reboot-required ]; then
    echo "System upgrade performed. A reboot is required. Please reboot and re-run the script."
    exit 0
fi

# Gather network information (default interface, IP, etc.)
# Find the primary network interface (with the default route)
DEFAULT_IF=$(ip -o -4 route show to default | awk '{print $5}')
if [[ -z "$DEFAULT_IF" ]]; then
    echo "ERROR: Could not detect primary network interface."
    exit 1
fi
HOST_IP=$(ip -4 -o addr show dev "$DEFAULT_IF" primary | awk '{print $4}' | cut -d/ -f1)
HOST_NAME=$(hostname -s)
GATEWAY_IP=$(ip -o -4 route show to default | awk '{print $3}')
echo "Detected primary interface: $DEFAULT_IF with IP $HOST_IP (gateway $GATEWAY_IP)"

# Check if a second interface (for external network) is available
EXT_IF=""  # will hold an external interface name if found
# Look for an interface that is UP, not lo or the primary, with no IP address
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v "^$DEFAULT_IF$" | grep -v "^lo$"); do
    # Check if interface is UP
    if ! ip link show dev "$iface" | grep -q "state UP"; then
        continue
    fi
    # Check if interface has no IPv4 address
    if ip addr show dev "$iface" | grep -q "inet "; then
        continue
    fi
    # If we get here, $iface has no IPv4 address and is UP
    EXT_IF="$iface"
    break
done
if [[ -n "$EXT_IF" ]]; then
    echo "Detected secondary interface: $EXT_IF (will be used for external network)"
else
    echo "No suitable secondary interface found. Using default NAT mode."
fi

# 2. Create Stack User for DevStack
###################################
# DevStack should run as a regular user (not root) with sudo privileges:contentReference[oaicite:8]{index=8}:contentReference[oaicite:9]{index=9}.
STACK_USER="stack"
if ! id -u "$STACK_USER" >/dev/null 2>&1; then
    echo "Creating user '$STACK_USER' for DevStack..."
    useradd -m -s /bin/bash -d /opt/stack "$STACK_USER"
    # Ensure the home directory has correct permissions (fix for Ubuntu 21.04+ umask issue):contentReference[oaicite:10]{index=10} 
    chmod 755 /opt/stack
fi
# Give stack user passwordless sudo
echo "$STACK_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99_stack_user

# 3. Define Default OpenStack Credentials
#########################################
# Using one strong password for all OpenStack services for simplicity:contentReference[oaicite:11]{index=11}.
ADMIN_PASS="OpenStack123"   # Admin password (Horizon dashboard, etc.)
DB_PASS="$ADMIN_PASS"       # Database (MySQL) root password
RABBIT_PASS="$ADMIN_PASS"   # RabbitMQ messaging password
SERVICE_PASS="$ADMIN_PASS"  # Common service user password

# Note: Use only alphanumeric passwords to avoid issues:contentReference[oaicite:12]{index=12}.
# (The default above is 12 characters, alphanumeric.)

# 4. Configure DevStack's local.conf
####################################
echo "Preparing DevStack configuration (local.conf)..."

# Switch to the stack user and run the remaining steps as that user
sudo -i -u "$STACK_USER" bash <<EOF
set -e

# Clone or update the DevStack repository (latest stable branch)
if [ ! -d "~/devstack" ]; then
    echo "Cloning DevStack repository..."
    git clone https://opendev.org/openstack/devstack ~/devstack
else
    echo "DevStack repository already exists. Updating..."
    cd ~/devstack
    # Backup any existing local.conf
    if [ -f "local.conf" ]; then
        cp local.conf local.conf.backup.$(date +%Y%m%d_%H%M%S)
        echo "Backed up existing local.conf"
    fi
    # Clean any uncommitted changes and update
    git stash push -u -m "Auto-stash before update $(date)"
    git checkout master || git checkout main || true
    git pull origin HEAD
    cd ~/
fi
cd ~/devstack

# Create local.conf with the necessary configuration
cat > local.conf <<LOCALCONF
[[local|localrc]]
# Credentials
ADMIN_PASSWORD=$ADMIN_PASS
DATABASE_PASSWORD=$DB_PASS
RABBIT_PASSWORD=$RABBIT_PASS
SERVICE_PASSWORD=$SERVICE_PASS

# Host network configuration
HOST_IP=$HOST_IP
EOF

# If a secondary interface is available, configure it for external network
if [[ -n "$EXT_IF" ]]; then
    echo "PUBLIC_INTERFACE=$EXT_IF" >> local.conf
    # Use the same network as HOST_IP for floating IPs (shared interface mode):contentReference[oaicite:13]{index=13}
    FLOAT_NET_CIDR="$(ip -o -4 addr show dev $DEFAULT_IF | awk '{print \$4}')"
    FLOAT_NET=\${FLOAT_NET_CIDR%/*}    # network address with prefix (e.g., 192.168.1.0/24)
    FLOAT_PREFIX=\${FLOAT_NET_CIDR#*/} # just the prefix number (e.g., 24)
    # Determine Floating IP allocation pool on the external network:
    # We'll allocate a small range at the high end of the subnet for Floating IPs.
    python3 - <<PYCODE
import ipaddress
import sys

try:
    net = ipaddress.ip_network(u"$FLOAT_NET_CIDR", strict=False)
    # Choose last 10 usable addresses as floating pool (or fewer if subnet is small)
    all_hosts = list(net.hosts())
    if len(all_hosts) > 0:
        start_ip = all_hosts[max(0, len(all_hosts)-10)]
        end_ip = all_hosts[-1]
        # Ensure start_ip is not the host IP or gateway
        reserved = {"$HOST_IP", "$GATEWAY_IP"}
        # If host or gateway are in the last addresses, adjust range to avoid them
        res_start = ipaddress.ip_address(min(int(start_ip), int(end_ip)))
        res_end = ipaddress.ip_address(max(int(start_ip), int(end_ip)))
        # Remove any reserved from the top range
        while str(res_end) in reserved and res_end >= net.network_address:
            res_end = ipaddress.ip_address(int(res_end) - 1)
        if res_end < net.network_address:
            # If we somehow ran out of addresses, just use host IP as pool (edge case small subnet)
            res_start = res_end = ipaddress.ip_address("$HOST_IP")
        res_start_val = int(res_end) - 9 if int(res_end) - int(net.network_address) >= 9 else int(net.network_address) + 1
        if res_start_val < int(net.network_address):
            res_start_val = int(net.network_address) + 1
        res_start = ipaddress.ip_address(res_start_val)
        # Avoid reserved at start as well
        while str(res_start) in reserved and res_start < res_end:
            res_start = ipaddress.ip_address(int(res_start) + 1)
        print(f"FLOATING_RANGE={net.network_address}/{net.prefixlen}")
        print(f"PUBLIC_NETWORK_GATEWAY=$GATEWAY_IP")
        print(f"Q_FLOATING_ALLOCATION_POOL=start={res_start},end={res_end}")
    else:
        print("# No usable host addresses in network")
        print("FLOATING_RANGE=172.24.4.0/24")
        print("PUBLIC_NETWORK_GATEWAY=172.24.4.1")
        print("Q_FLOATING_ALLOCATION_POOL=start=172.24.4.225,end=172.24.4.254")
except Exception as e:
    print(f"# Error calculating floating range: {e}", file=sys.stderr)
    print("FLOATING_RANGE=172.24.4.0/24")
    print("PUBLIC_NETWORK_GATEWAY=172.24.4.1") 
    print("Q_FLOATING_ALLOCATION_POOL=start=172.24.4.225,end=172.24.4.254")
PYCODE
    >> local.conf
else
    # No second interface: default DevStack NAT mode for external networking
    # (Floating IP network will be 172.24.4.0/24 by default):contentReference[oaicite:14]{index=14}:contentReference[oaicite:15]{index=15}.
    echo "# Using default NAT-based floating network (172.24.4.0/24)" >> local.conf
fi

# Enable useful services (Horizon dashboard is enabled by default in DevStack)
# In case we want to ensure Horizon and Neutron are enabled:
echo "enable_service horizon" >> local.conf
echo "enable_service q-svc q-agt q-dhcp q-l3 q-meta" >> local.conf

LOCALCONF

# Display the generated local.conf for reference
echo "Generated local.conf:"
cat local.conf

# 5. Run DevStack installation
##############################
echo "Running DevStack (this will take ~10-20 minutes)..."
cd ~/devstack

# Verify we're in the correct directory and stack.sh exists
if [ ! -f "./stack.sh" ]; then
    echo "ERROR: stack.sh not found in $(pwd). DevStack may not be properly cloned."
    exit 1
fi

# Check if DevStack is already running
if [ -f "/opt/stack/status/stack/nova-api.pid" ] || [ -f ".stack-status" ]; then
    echo "DevStack appears to be already running. You may want to run './unstack.sh' first."
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting. Run './unstack.sh' to stop existing services, then re-run this script."
        exit 0
    fi
fi

./stack.sh

# 6. Post-Installation: OpenStack Initialization
###############################################
# Source the OpenStack credentials and open up default security group
source ~/devstack/openrc admin admin  # load admin credentials
# Allow ping (ICMP) and SSH (TCP/22) to instances by default:contentReference[oaicite:16]{index=16}:contentReference[oaicite:17]{index=17}
openstack security group rule create --proto icmp --dst-port 0 default
openstack security group rule create --proto tcp --dst-port 22 default

echo "DevStack installation complete."
echo "Horizon dashboard URL: http://$HOST_IP/ (user: admin, password: $ADMIN_PASS)" 
EOF

