#!/usr/bin/env bash
# Quick deployment script for testing

set -euo pipefail

echo "=== OpenStack Quick Deploy ==="

# Run cleanup first
echo "1. Running cleanup..."
sudo ./force_cleanup.sh

echo "2. Waiting for cleanup to complete..."
sleep 10

# Deploy controller
echo "3. Starting controller deployment..."
sudo ./deploy_controller.sh --password OpenStack123

echo "=== Deployment Complete ==="