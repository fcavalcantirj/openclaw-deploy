#!/usr/bin/env bash
set -euo pipefail

# restart.sh - Restart OpenClaw gateway on an instance
# Usage: ./scripts/restart.sh <instance-name>

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

usage() {
  cat << EOF
Usage: $0 <instance-name>

Restart the OpenClaw gateway service on a deployed instance.

Arguments:
  instance-name    Name of the deployed instance

Examples:
  $0 mybot         # Restart the gateway on mybot instance

What this does:
  1. Stops the OpenClaw gateway service
  2. Waits briefly for clean shutdown
  3. Starts the gateway service
  4. Verifies it's running
  5. Shows recent logs

Use cases:
  • Apply configuration changes
  • Recover from errors
  • Clear stuck states
  • Reload after updates

EOF
  exit 1
}

# Validate arguments
if [ $# -ne 1 ]; then
  usage
fi

INSTANCE_NAME="$1"

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
info "Restarting OpenClaw gateway: $INSTANCE_NAME"
info "Instance IP: $IP"
echo

# Check current status
info "Checking current status..."
CURRENT_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "systemctl --user is-active openclaw-gateway 2>&1 || echo 'inactive'")

echo -e "  Current status: ${YELLOW}$CURRENT_STATUS${NC}"
echo

# Stop the gateway
info "Stopping gateway..."
STOP_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "systemctl --user stop openclaw-gateway 2>&1 || echo 'STOP_FAILED'")

if echo "$STOP_OUTPUT" | grep -qi "STOP_FAILED"; then
  echo -e "${YELLOW}⚠ Warning: Stop command may have failed${NC}"
  echo "$STOP_OUTPUT"
else
  success "Gateway stopped"
fi

# Wait for clean shutdown
info "Waiting for clean shutdown..."
sleep 2

# Start the gateway
info "Starting gateway..."
START_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "systemctl --user start openclaw-gateway 2>&1 || echo 'START_FAILED'")

if echo "$START_OUTPUT" | grep -qi "START_FAILED"; then
  error "Failed to start gateway:\n$START_OUTPUT"
fi

success "Gateway started"
echo

# Wait for startup
info "Waiting for gateway initialization..."
sleep 3

# Verify it's running
info "Verifying gateway status..."
NEW_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "systemctl --user is-active openclaw-gateway 2>&1 || echo 'inactive'")

if echo "$NEW_STATUS" | grep -qi "active"; then
  success "Gateway is running"
else
  error "Gateway failed to start. Status: $NEW_STATUS

Troubleshooting:
  1. Check logs: ./scripts/logs.sh $INSTANCE_NAME
  2. Check status: ./scripts/status.sh $INSTANCE_NAME
  3. SSH to instance: ssh -i '$SSH_KEY' openclaw@$IP
  4. Manual check: systemctl --user status openclaw-gateway"
fi

echo

# Check with OpenClaw CLI
info "Verifying via OpenClaw CLI..."
CLI_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw gateway status 2>&1 || echo 'CLI_FAILED'")

if echo "$CLI_STATUS" | grep -qi "running\|active"; then
  success "Gateway responding normally"
  echo
  echo "$CLI_STATUS"
else
  echo -e "${YELLOW}⚠ Warning: CLI check inconclusive${NC}"
  echo "$CLI_STATUS"
fi

echo

# Show recent logs
info "Recent logs (last 10 lines):"
echo
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "journalctl --user -u openclaw-gateway -n 10 --no-pager 2>&1" || echo "Could not fetch logs"

echo
success "Restart complete!"
echo

# Summary
echo -e "${BLUE}Summary:${NC}"
echo -e "  Instance:     ${YELLOW}$INSTANCE_NAME${NC}"
echo -e "  Old status:   ${YELLOW}$CURRENT_STATUS${NC}"
echo -e "  New status:   ${GREEN}$NEW_STATUS${NC}"
echo

echo -e "${BLUE}Next steps:${NC}"
echo -e "  • Monitor logs: ${YELLOW}./scripts/receive-check.sh $INSTANCE_NAME --follow${NC}"
echo -e "  • Check status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
echo -e "  • Full verify: ${YELLOW}ssh -i '$SSH_KEY' openclaw@$IP './scripts/verify.sh'${NC}"
echo
