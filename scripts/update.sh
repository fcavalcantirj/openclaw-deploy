#!/usr/bin/env bash
set -euo pipefail

# update.sh - Update OpenClaw version on an instance
# Usage: ./scripts/update.sh <instance-name> [version]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
error() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

info() {
  echo -e "${BLUE}INFO: $1${NC}"
}

success() {
  echo -e "${GREEN}✓ $1${NC}"
}

warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

usage() {
  cat << EOF
Usage: $0 <instance-name> [version]

Update OpenClaw to a specific version or latest on a deployed instance.

Arguments:
  instance-name    Name of the deployed instance
  version          Version to install (e.g., '0.5.0', 'latest')
                   Default: latest

Examples:
  $0 mybot                    # Update to latest version
  $0 mybot latest             # Update to latest version
  $0 mybot 0.5.0              # Update to specific version

What this does:
  1. Checks current version
  2. Stops the gateway service
  3. Updates OpenClaw via npm
  4. Verifies installation
  5. Restarts the gateway
  6. Validates new version
  7. Updates metadata

Notes:
  • Configuration is preserved across updates
  • Gateway is restarted automatically
  • Rollback instructions shown if update fails

EOF
  exit 1
}

# Validate arguments
if [ $# -lt 1 ]; then
  usage
fi

INSTANCE_NAME="$1"
VERSION="${2:-latest}"

# Check if instance exists
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  error "Instance '$INSTANCE_NAME' not found. Run ./scripts/list.sh to see available instances."
fi

# Load instance metadata
IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key' "$METADATA_FILE")

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  error "Instance IP not found in metadata"
fi

if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
fi

echo
info "Updating OpenClaw on instance: $INSTANCE_NAME"
info "Instance IP: $IP"
info "Target version: $VERSION"
echo

# Get current version
info "Checking current version..."
CURRENT_VERSION=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw --version 2>&1 | head -1" || echo "unknown")

echo -e "  Current version: ${YELLOW}$CURRENT_VERSION${NC}"
echo

# Confirm update
warning "This will stop the gateway, update OpenClaw, and restart."
echo -e "${YELLOW}Press Ctrl+C within 5 seconds to cancel...${NC}"
sleep 5

echo
info "Proceeding with update..."
echo

# Stop the gateway
info "Stopping gateway..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "sudo systemctl stop openclaw-gateway" || warning "Stop command may have failed"

success "Gateway stopped"
echo

# Wait for clean shutdown
info "Waiting for clean shutdown..."
sleep 2

# Update OpenClaw
info "Updating OpenClaw to $VERSION..."
echo

if [ "$VERSION" = "latest" ]; then
  UPDATE_CMD="npm install -g openclaw@latest"
else
  UPDATE_CMD="npm install -g openclaw@$VERSION"
fi

UPDATE_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=30 \
  "openclaw@$IP" "$UPDATE_CMD 2>&1" || echo "UPDATE_FAILED")

if echo "$UPDATE_OUTPUT" | grep -qi "UPDATE_FAILED\|error\|failed"; then
  echo "$UPDATE_OUTPUT"
  error "Update failed. Gateway is stopped. Manual intervention required:

  1. SSH to instance: ssh -i '$SSH_KEY' openclaw@$IP
  2. Check npm logs: npm install -g openclaw@$VERSION
  3. Restart gateway: sudo systemctl start openclaw-gateway"
fi

echo "$UPDATE_OUTPUT" | tail -10
echo

success "OpenClaw updated"

# Verify new version
info "Verifying new version..."
NEW_VERSION=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw --version 2>&1 | head -1" || echo "unknown")

echo -e "  New version: ${GREEN}$NEW_VERSION${NC}"
echo

# Start the gateway
info "Starting gateway..."
START_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "sudo systemctl start openclaw-gateway 2>&1" || echo "START_FAILED")

if echo "$START_OUTPUT" | grep -qi "START_FAILED"; then
  error "Failed to start gateway:\n$START_OUTPUT

Manual recovery:
  1. SSH to instance: ssh -i '$SSH_KEY' openclaw@$IP
  2. Check status: sudo systemctl status openclaw-gateway
  3. Check logs: sudo journalctl -u openclaw-gateway -n 50
  4. Try starting: sudo systemctl start openclaw-gateway"
fi

success "Gateway started"
echo

# Wait for startup
info "Waiting for gateway initialization..."
sleep 3

# Verify it's running
info "Verifying gateway status..."
GATEWAY_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw gateway status 2>&1 || echo 'OFFLINE'")

if echo "$GATEWAY_STATUS" | grep -qi "running\|active"; then
  success "Gateway is running with new version"
  echo
  echo "$GATEWAY_STATUS"
else
  warning "Gateway status unclear. Please verify manually."
  echo "$GATEWAY_STATUS"
fi

echo

# Update metadata
info "Updating metadata..."
jq --arg version "$NEW_VERSION" '.openclaw_version = $version' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
success "Metadata updated"

echo
success "Update complete!"
echo

# Summary
echo -e "${BLUE}Summary:${NC}"
echo -e "  Instance:        ${YELLOW}$INSTANCE_NAME${NC}"
echo -e "  Old version:     ${YELLOW}$CURRENT_VERSION${NC}"
echo -e "  New version:     ${GREEN}$NEW_VERSION${NC}"
echo -e "  Gateway status:  ${GREEN}running${NC}"
echo

echo -e "${BLUE}Next steps:${NC}"
echo -e "  • Monitor logs: ${YELLOW}./scripts/receive-check.sh $INSTANCE_NAME --follow${NC}"
echo -e "  • Run verification: ${YELLOW}ssh -i '$SSH_KEY' openclaw@$IP './scripts/verify.sh'${NC}"
echo -e "  • Check status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
echo
