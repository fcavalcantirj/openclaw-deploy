#!/usr/bin/env bash
set -euo pipefail

# logs.sh - Fetch and display logs from an OpenClaw instance
# Usage: ./scripts/logs.sh <instance-name> [options]

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
LINES=50
FOLLOW=false
SINCE=""
SERVICE="openclaw-gateway"

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

Fetch and display logs from an OpenClaw instance's gateway service.

Arguments:
  instance-name    Name of the deployed instance

Options:
  -n, --lines N    Number of log lines to show (default: 50)
  -f, --follow     Follow logs in real-time (like tail -f)
  -s, --since      Show logs since time (e.g., '10m', '1h', 'today')
  -e, --errors     Show only error/warning logs
  -a, --all        Show all available logs (no line limit)
  -h, --help       Show this help message

Examples:
  $0 mybot                      # Show last 50 log lines
  $0 mybot -n 200               # Show last 200 lines
  $0 mybot --follow             # Follow logs in real-time
  $0 mybot --since '10m'        # Show logs from last 10 minutes
  $0 mybot --since 'today'      # Show today's logs
  $0 mybot --errors             # Show only errors and warnings

Time formats for --since:
  10s, 5m, 2h, 1d (seconds, minutes, hours, days)
  today, yesterday
  '2026-02-13 14:00:00'

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
ERRORS_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--lines)
      LINES="$2"
      shift 2
      ;;
    -f|--follow)
      FOLLOW=true
      shift
      ;;
    -s|--since)
      SINCE="$2"
      shift 2
      ;;
    -e|--errors)
      ERRORS_ONLY=true
      shift
      ;;
    -a|--all)
      LINES=""
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

# Build journalctl command
JOURNAL_CMD="journalctl --user -u $SERVICE --no-pager"

if [ "$FOLLOW" = true ]; then
  JOURNAL_CMD="$JOURNAL_CMD -f"
elif [ -n "$LINES" ]; then
  JOURNAL_CMD="$JOURNAL_CMD -n $LINES"
fi

if [ -n "$SINCE" ]; then
  JOURNAL_CMD="$JOURNAL_CMD --since '$SINCE'"
fi

if [ "$ERRORS_ONLY" = true ]; then
  JOURNAL_CMD="$JOURNAL_CMD -p warning"
fi

# Display header
echo
if [ "$FOLLOW" = true ]; then
  info "Following logs for: $INSTANCE_NAME (Ctrl+C to stop)"
else
  info "Fetching logs for: $INSTANCE_NAME"
fi
info "Instance IP: $IP"
info "Service: $SERVICE"
if [ -n "$SINCE" ]; then
  info "Since: $SINCE"
fi
if [ -n "$LINES" ] && [ "$FOLLOW" = false ]; then
  info "Lines: $LINES"
fi
if [ "$ERRORS_ONLY" = true ]; then
  info "Filter: Errors and warnings only"
fi
echo

# Fetch logs
if [ "$FOLLOW" = true ]; then
  # Follow mode - stream logs
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "$JOURNAL_CMD"
else
  # Fetch mode - get logs and colorize
  info "Fetching logs..."
  echo

  LOG_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "$JOURNAL_CMD 2>&1" || echo "LOG_FETCH_FAILED")

  if [ "$LOG_OUTPUT" = "LOG_FETCH_FAILED" ]; then
    error "Failed to fetch logs from instance"
  fi

  # Check if logs are empty
  if [ -z "$LOG_OUTPUT" ] || echo "$LOG_OUTPUT" | grep -qi "no entries\|no journal"; then
    echo -e "${YELLOW}No logs found matching criteria${NC}"
    echo
    exit 0
  fi

  # Colorize output based on log levels and content
  echo "$LOG_OUTPUT" | while IFS= read -r line; do
    if echo "$line" | grep -qi "error\|critical\|fatal"; then
      echo -e "${RED}$line${NC}"
    elif echo "$line" | grep -qi "warn\|warning"; then
      echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -qi "incoming\|received\|message"; then
      echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -qi "sent\|deliver\|success"; then
      echo -e "${CYAN}$line${NC}"
    elif echo "$line" | grep -qi "pairing\|pair"; then
      echo -e "${BLUE}$line${NC}"
    else
      echo "$line"
    fi
  done

  echo
  success "Log fetch complete"
  echo

  # Show helpful next steps
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  • Follow logs in real-time: ${YELLOW}$0 $INSTANCE_NAME --follow${NC}"
  echo -e "  • Show more history: ${YELLOW}$0 $INSTANCE_NAME -n 200${NC}"
  echo -e "  • Show recent errors: ${YELLOW}$0 $INSTANCE_NAME --errors${NC}"
  echo -e "  • Show logs since 10 min ago: ${YELLOW}$0 $INSTANCE_NAME --since '10m'${NC}"
  echo -e "  • Check instance status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
  echo
fi
