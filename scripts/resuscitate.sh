#!/usr/bin/env bash
set -euo pipefail

# resuscitate.sh - Recover crashed or unresponsive OpenClaw instances
# Usage: ./scripts/resuscitate.sh <instance-name> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
Usage: $0 <instance-name> [options]

Attempt to recover a crashed or unresponsive OpenClaw instance.

Arguments:
  instance-name    Name of the deployed instance

Options:
  --force          Skip diagnostics and force recovery immediately
  --dry-run        Show what would be done without doing it
  -h, --help       Show this help message

Examples:
  $0 mybot                # Diagnose and recover instance
  $0 mybot --force        # Force immediate recovery
  $0 mybot --dry-run      # Preview recovery actions

Recovery steps:
  1. Diagnose the issue (connectivity, process, disk, etc.)
  2. Collect diagnostic logs
  3. Stop any stuck processes
  4. Clear temporary files if needed
  5. Restart the gateway service
  6. Verify recovery
  7. Report results

When to use:
  • Gateway won't start
  • Instance is unresponsive
  • Repeated crashes
  • After unexpected shutdowns
  • Resource exhaustion issues

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ -z "$INSTANCE_NAME" ]; then
        INSTANCE_NAME="$1"
        shift
      else
        error "Unknown option: $1"
      fi
      ;;
  esac
done

# Validate instance name
if [ -z "$INSTANCE_NAME" ]; then
  usage
fi

# Check if instance exists
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  error "Instance '$INSTANCE_NAME' not found. Run ./scripts/list.sh to see available instances."
fi

# Load instance metadata
IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key_path // .ssh_key' "$METADATA_FILE")

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  error "Instance IP not found in metadata"
fi

if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
fi

echo
info "Resuscitating instance: $INSTANCE_NAME"
info "Instance IP: $IP"
if [ "$DRY_RUN" = true ]; then
  warning "DRY RUN MODE - No changes will be made"
fi
echo

# Step 1: Check SSH connectivity
info "Step 1/7: Checking SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
     "openclaw@$IP" "echo ok" > /dev/null 2>&1; then
  error "Cannot connect via SSH. Possible issues:
  • VM is down or frozen
  • Network connectivity issues
  • SSH daemon not running

Manual recovery required:
  1. Check VM status: hcloud server describe $INSTANCE_NAME
  2. Try console access via Hetzner dashboard
  3. Consider VM reboot or rebuild"
fi
success "SSH connectivity OK"
echo

# Step 2: Diagnose system resources
if [ "$FORCE" = false ]; then
  info "Step 2/7: Diagnosing system resources..."

  # Check disk space
  DISK_USAGE=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'" || echo "0")

  echo -e "  Disk usage: ${CYAN}${DISK_USAGE}%${NC}"

  if [ "$DISK_USAGE" -gt 95 ]; then
    warning "Critical disk space! Attempting cleanup..."
    if [ "$DRY_RUN" = false ]; then
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "openclaw@$IP" "journalctl --vacuum-time=7d 2>&1 || true"
      success "Log cleanup completed"
    else
      echo "  Would run: journalctl --vacuum-time=7d"
    fi
  fi

  # Check memory
  MEM_INFO=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "free -h | grep Mem" || echo "unknown")

  echo -e "  Memory: ${CYAN}$MEM_INFO${NC}"

  # Check load average
  LOAD_AVG=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "uptime | awk -F'load average:' '{print \$2}'" || echo "unknown")

  echo -e "  Load: ${CYAN}$LOAD_AVG${NC}"

  success "System diagnostics complete"
  echo
else
  info "Step 2/7: Skipping diagnostics (--force mode)"
  echo
fi

# Step 3: Collect error logs
if [ "$FORCE" = false ]; then
  info "Step 3/7: Collecting recent error logs..."

  ERROR_LOGS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo journalctl -u openclaw-gateway --since '1 hour ago' -p err --no-pager -n 20 2>&1" || echo "No logs")

  if echo "$ERROR_LOGS" | grep -q "error\|Error\|ERROR"; then
    warning "Recent errors detected:"
    echo "$ERROR_LOGS" | head -10
    echo
  else
    echo -e "  ${CYAN}No recent errors in logs${NC}"
  fi

  success "Log collection complete"
  echo
else
  info "Step 3/7: Skipping log collection (--force mode)"
  echo
fi

# Step 4: Stop stuck processes
info "Step 4/7: Checking for stuck processes..."

GATEWAY_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "sudo systemctl is-active openclaw-gateway 2>&1" || echo "inactive")

echo -e "  Gateway status: ${CYAN}$GATEWAY_STATUS${NC}"

if [ "$GATEWAY_STATUS" = "active" ] || [ "$GATEWAY_STATUS" = "activating" ]; then
  info "Stopping gateway service..."
  if [ "$DRY_RUN" = false ]; then
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "sudo systemctl stop openclaw-gateway 2>&1 || true"
    sleep 2
    success "Gateway stopped"
  else
    echo "  Would run: sudo systemctl stop openclaw-gateway"
  fi
fi

# Check for orphaned OpenClaw processes
ORPHANED=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "pgrep -f openclaw | wc -l" || echo "0")

if [ "$ORPHANED" -gt 0 ]; then
  warning "Found $ORPHANED orphaned OpenClaw processes"
  if [ "$DRY_RUN" = false ]; then
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "pkill -f openclaw || true"
    sleep 1
    success "Orphaned processes terminated"
  else
    echo "  Would run: pkill -f openclaw"
  fi
fi

success "Process cleanup complete"
echo

# Step 5: Clear temporary files
info "Step 5/7: Clearing temporary files..."

if [ "$DRY_RUN" = false ]; then
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "rm -f /tmp/openclaw-* 2>&1 || true"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "rm -f ~/.openclaw/*.lock 2>&1 || true"
  success "Temporary files cleared"
else
  echo "  Would clear: /tmp/openclaw-* and ~/.openclaw/*.lock"
fi

echo

# Step 6: Restart gateway
info "Step 6/7: Restarting gateway service..."

if [ "$DRY_RUN" = false ]; then
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo systemctl start openclaw-gateway 2>&1" || \
    warning "Start command may have failed"

  sleep 3

  success "Gateway restart initiated"
else
  echo "  Would run: sudo systemctl start openclaw-gateway"
fi

echo

# Step 7: Verify recovery
info "Step 7/7: Verifying recovery..."

if [ "$DRY_RUN" = false ]; then
  sleep 2

  # Check service status
  NEW_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo systemctl is-active openclaw-gateway 2>&1" || echo "inactive")

  echo -e "  Service status: ${CYAN}$NEW_STATUS${NC}"

  if [ "$NEW_STATUS" = "active" ]; then
    success "Service is running"
  else
    warning "Service may not have started correctly"
  fi

  # Check CLI
  CLI_CHECK=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "openclaw gateway status 2>&1 | grep -iq 'running\|active' && echo 'OK' || echo 'FAILED'")

  echo -e "  CLI status: ${CYAN}$CLI_CHECK${NC}"

  if [ "$CLI_CHECK" = "OK" ]; then
    success "Gateway is responding"
  else
    warning "Gateway may not be fully operational"
  fi

  # Check recent logs for errors
  STARTUP_ERRORS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo journalctl -u openclaw-gateway --since '1 minute ago' -p err --no-pager 2>&1 | grep -c '^' || echo 0")

  if [ "$STARTUP_ERRORS" -gt 0 ]; then
    warning "$STARTUP_ERRORS error(s) in startup logs"
    echo
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "sudo journalctl -u openclaw-gateway --since '1 minute ago' -p err --no-pager -n 5 2>&1"
  else
    success "No startup errors detected"
  fi
else
  echo "  Would verify: service status, CLI responsiveness, startup logs"
fi

echo

# Final report
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                 RECOVERY SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}DRY RUN completed - no changes were made${NC}"
  echo
  echo "To perform actual recovery, run without --dry-run:"
  echo -e "  ${YELLOW}$0 $INSTANCE_NAME${NC}"
elif [ "$NEW_STATUS" = "active" ] && [ "$CLI_CHECK" = "OK" ] && [ "$STARTUP_ERRORS" -eq 0 ]; then
  success "Instance successfully resuscitated!"
  echo
  echo -e "${GREEN}All checks passed. Instance is operational.${NC}"
  echo
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  • Monitor for stability: ${YELLOW}./scripts/monitor-all.sh --watch 60${NC}"
  echo -e "  • Check full status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
  echo -e "  • Follow logs: ${YELLOW}./scripts/logs.sh $INSTANCE_NAME --follow${NC}"
else
  warning "Recovery completed with warnings"
  echo
  echo -e "${YELLOW}Instance may not be fully operational. Review the diagnostics above.${NC}"
  echo
  echo -e "${BLUE}Troubleshooting:${NC}"
  echo -e "  • View detailed logs: ${YELLOW}./scripts/logs.sh $INSTANCE_NAME -n 100 --errors${NC}"
  echo -e "  • Check configuration: ${YELLOW}./scripts/config-view.sh $INSTANCE_NAME${NC}"
  echo -e "  • Manual SSH access: ${YELLOW}ssh -i '$SSH_KEY' openclaw@$IP${NC}"
  echo -e "  • Consider update: ${YELLOW}./scripts/update.sh $INSTANCE_NAME${NC}"
  echo -e "  • Last resort: ${YELLOW}./scripts/destroy.sh $INSTANCE_NAME && ./deploy.sh --name $INSTANCE_NAME${NC}"
fi

echo
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo
