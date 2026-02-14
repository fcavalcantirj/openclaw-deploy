#!/usr/bin/env bash
set -euo pipefail

# receive-check.sh - Check for new messages/events on an OpenClaw instance
# Usage: ./scripts/receive-check.sh <instance-name> [options]

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

# Default options
TAIL_LINES=20
FOLLOW=false
CHANNEL="telegram"

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
Usage: $0 <instance-name> [options]

Check for new messages and events on an OpenClaw instance.

Arguments:
  instance-name    Name of the deployed instance

Options:
  -n, --lines N    Number of log lines to show (default: 20)
  -f, --follow     Follow logs in real-time (like tail -f)
  -c, --channel    Channel to check (default: telegram)
  -a, --all        Show all channels
  -h, --help       Show this help message

Examples:
  $0 mybot                    # Check recent messages
  $0 mybot -n 50              # Check last 50 log entries
  $0 mybot --follow           # Follow logs in real-time
  $0 mybot -c telegram -f     # Follow Telegram channel logs

What this checks:
  • Recent gateway logs for incoming messages
  • Pairing requests
  • Message delivery status
  • Channel activity
  • Error events

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--lines)
      TAIL_LINES="$2"
      shift 2
      ;;
    -f|--follow)
      FOLLOW=true
      shift
      ;;
    -c|--channel)
      CHANNEL="$2"
      shift 2
      ;;
    -a|--all)
      CHANNEL="all"
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
SSH_KEY=$(jq -r '.ssh_key' "$METADATA_FILE")

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  error "Instance IP not found in metadata"
fi

if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
fi

echo
info "Checking messages/events for: $INSTANCE_NAME"
info "Instance IP: $IP"
echo

# Check gateway status first
info "Checking gateway status..."
GATEWAY_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw gateway status 2>&1 || echo 'OFFLINE'")

if echo "$GATEWAY_STATUS" | grep -qi "running\|active"; then
  success "Gateway is running"
else
  echo -e "${YELLOW}⚠ Gateway may not be running${NC}"
  echo "$GATEWAY_STATUS"
fi

echo

# Check for pending pairing requests
info "Checking for pending pairing requests..."
PAIRING_REQUESTS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw pairing pending $CHANNEL 2>&1 || echo 'NONE'")

if echo "$PAIRING_REQUESTS" | grep -qi "no pending\|none\|empty"; then
  echo -e "${CYAN}  No pending pairing requests${NC}"
else
  echo -e "${YELLOW}Pending pairing requests:${NC}"
  echo "$PAIRING_REQUESTS"
fi

echo

# Get channel activity summary
info "Channel activity summary..."
CHANNEL_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw channels status 2>&1 || echo 'UNAVAILABLE'")

if [ "$CHANNEL_STATUS" != "UNAVAILABLE" ]; then
  echo "$CHANNEL_STATUS" | grep -i "$CHANNEL\|enabled\|active" || echo -e "${CYAN}  No channel info available${NC}"
else
  echo -e "${CYAN}  Channel status unavailable${NC}"
fi

echo

# Fetch gateway logs
if [ "$FOLLOW" = true ]; then
  info "Following gateway logs (Ctrl+C to stop)..."
  echo
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo journalctl -u openclaw-gateway -f --no-pager"
else
  info "Recent gateway logs (last $TAIL_LINES entries):"
  echo

  # Fetch and format logs
  LOG_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "sudo journalctl -u openclaw-gateway -n $TAIL_LINES --no-pager 2>&1" || echo "LOG_FETCH_FAILED")

  if [ "$LOG_OUTPUT" = "LOG_FETCH_FAILED" ]; then
    error "Failed to fetch logs from instance"
  fi

  # Highlight interesting patterns
  echo "$LOG_OUTPUT" | while IFS= read -r line; do
    if echo "$line" | grep -qi "incoming\|received\|message"; then
      echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -qi "error\|failed\|warn"; then
      echo -e "${RED}$line${NC}"
    elif echo "$line" | grep -qi "pairing\|pair"; then
      echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -qi "sent\|deliver"; then
      echo -e "${CYAN}$line${NC}"
    else
      echo "$line"
    fi
  done

  echo
  success "Log check complete"
  echo

  # Suggest next steps
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  • Follow logs in real-time: ${YELLOW}$0 $INSTANCE_NAME --follow${NC}"
  echo -e "  • Check more history: ${YELLOW}$0 $INSTANCE_NAME -n 100${NC}"
  echo -e "  • Approve pending pairings: ${YELLOW}./scripts/approve-user.sh $INSTANCE_NAME${NC}"
  echo -e "  • Send a message: ${YELLOW}./scripts/send-message.sh $INSTANCE_NAME <target> '<message>'${NC}"
  echo
fi
