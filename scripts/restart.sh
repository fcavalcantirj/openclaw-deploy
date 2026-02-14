#!/usr/bin/env bash
set -euo pipefail

# restart.sh - Restart OpenClaw gateway on an instance
# Usage: ./scripts/restart.sh <instance-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

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

EOF
  exit 1
}

# Validate arguments
if [ $# -ne 1 ]; then
  usage
fi

INSTANCE_NAME="$1"
load_instance "$INSTANCE_NAME" || exit 1

if [[ ! -f "$INSTANCE_SSH_KEY" ]]; then
  log_error "SSH key not found at $INSTANCE_SSH_KEY"
  exit 1
fi

echo
log_info "Restarting OpenClaw gateway: $INSTANCE_NAME"
log_info "Instance IP: $INSTANCE_IP (user: $INSTANCE_SSH_USER)"
echo

# Check current status
log_info "Checking current status..."
CURRENT_STATUS=$(ssh_exec "$INSTANCE_NAME" "systemctl is-active openclaw-gateway 2>&1 || echo 'inactive'")

echo -e "  Current status: ${YELLOW}$CURRENT_STATUS${NC}"
echo

# Stop the gateway
log_info "Stopping gateway..."
STOP_OUTPUT=$(ssh_exec "$INSTANCE_NAME" "systemctl stop openclaw-gateway 2>&1 || echo 'STOP_FAILED'")

if echo "$STOP_OUTPUT" | grep -qi "STOP_FAILED"; then
  log_warn "Stop command may have failed"
  echo "$STOP_OUTPUT"
else
  log_success "Gateway stopped"
fi

# Wait for clean shutdown
log_info "Waiting for clean shutdown..."
sleep 2

# Start the gateway
log_info "Starting gateway..."
START_OUTPUT=$(ssh_exec "$INSTANCE_NAME" "systemctl start openclaw-gateway 2>&1 || echo 'START_FAILED'")

if echo "$START_OUTPUT" | grep -qi "START_FAILED"; then
  log_error "Failed to start gateway"
  echo "$START_OUTPUT"
  exit 1
fi

log_success "Gateway started"
echo

# Wait for startup
log_info "Waiting for gateway initialization..."
sleep 3

# Verify it's running
log_info "Verifying gateway status..."
NEW_STATUS=$(ssh_exec "$INSTANCE_NAME" "systemctl is-active openclaw-gateway 2>&1 || echo 'inactive'")

if echo "$NEW_STATUS" | grep -qi "active"; then
  log_success "Gateway is running"
else
  log_error "Gateway failed to start. Status: $NEW_STATUS"
  echo
  echo "Troubleshooting:"
  echo "  1. Check logs: ./scripts/logs.sh $INSTANCE_NAME"
  echo "  2. Check status: ./scripts/status.sh $INSTANCE_NAME"
  echo "  3. SSH to instance: claw ssh $INSTANCE_NAME"
  exit 1
fi

echo

# Check with OpenClaw CLI
log_info "Verifying via OpenClaw CLI..."
CLI_STATUS=$(ssh_exec "$INSTANCE_NAME" "openclaw gateway status 2>&1 || echo 'CLI_FAILED'")

if echo "$CLI_STATUS" | grep -qi "running\|active"; then
  log_success "Gateway responding normally"
  echo
  echo "$CLI_STATUS"
else
  log_warn "CLI check inconclusive"
  echo "$CLI_STATUS"
fi

echo

# Show recent logs
log_info "Recent logs (last 10 lines):"
echo
ssh_exec "$INSTANCE_NAME" "journalctl -u openclaw-gateway -n 10 --no-pager 2>&1" || echo "Could not fetch logs"

echo
log_success "Restart complete!"
echo

# Summary
echo -e "${BLUE}Summary:${NC}"
echo -e "  Instance:     ${YELLOW}$INSTANCE_NAME${NC}"
echo -e "  Old status:   ${YELLOW}$CURRENT_STATUS${NC}"
echo -e "  New status:   ${GREEN}$NEW_STATUS${NC}"
echo

echo -e "${BLUE}Next steps:${NC}"
echo -e "  • Monitor logs: ${YELLOW}claw logs $INSTANCE_NAME -f${NC}"
echo -e "  • Check status: ${YELLOW}claw status $INSTANCE_NAME${NC}"
echo
