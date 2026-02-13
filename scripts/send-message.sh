#!/usr/bin/env bash
set -euo pipefail

# send-message.sh - Send message to user via OpenClaw instance
# Usage: ./scripts/send-message.sh <instance-name> <target> <message>

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
Usage: $0 <instance-name> <target> <message>
       $0 <instance-name> --owner <message>

Send messages to users via an OpenClaw instance's Telegram bot.

Arguments:
  instance-name    Name of the deployed instance
  target           Telegram user ID (e.g., 123456789) or username (e.g., @username)
  --owner          Send to the instance owner (paired user)
  message          The message to send (use quotes for multi-word messages)

Examples:
  $0 mybot 123456789 'Hello from OpenClaw!'
  $0 mybot @username 'Your bot is ready!'
  $0 mybot --owner 'Welcome! Your bot is online.'

Notes:
  - User must be paired with the bot before messages can be sent
  - Use 'openclaw pairing list telegram' on the VM to see paired users
  - For owner messages, the first paired user will be used

EOF
  exit 1
}

# Validate arguments
if [ $# -lt 2 ]; then
  usage
fi

INSTANCE_NAME="$1"
TARGET="$2"
MESSAGE=""

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

# Handle --owner flag
if [ "$TARGET" = "--owner" ]; then
  if [ $# -lt 3 ]; then
    error "Message required. Usage: $0 $INSTANCE_NAME --owner '<message>'"
  fi
  MESSAGE="$3"

  echo
  info "Sending message to instance owner: $INSTANCE_NAME"
  info "Retrieving owner information..."
  echo

  # Get the first paired user from the instance
  PAIRED_USERS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "openclaw pairing list telegram 2>&1" || echo "")

  if [ -z "$PAIRED_USERS" ] || echo "$PAIRED_USERS" | grep -qi "no paired\|empty"; then
    error "No paired users found. User must pair with the bot first."
  fi

  # Extract first user ID (simple parsing - assumes output format)
  # This is a best-effort approach; adjust based on actual CLI output
  OWNER_ID=$(echo "$PAIRED_USERS" | grep -oE '[0-9]{6,}' | head -1)

  if [ -z "$OWNER_ID" ]; then
    error "Could not determine owner ID. Paired users output:\n$PAIRED_USERS"
  fi

  info "Owner ID: $OWNER_ID"
  TARGET="$OWNER_ID"
else
  # Regular target and message
  if [ $# -lt 3 ]; then
    error "Message required. Usage: $0 $INSTANCE_NAME <target> '<message>'"
  fi
  MESSAGE="$3"

  echo
  info "Sending message to user via instance: $INSTANCE_NAME"
  info "Target: $TARGET"
  echo
fi

# Validate target format
if [[ "$TARGET" =~ ^@[a-zA-Z0-9_]{5,}$ ]]; then
  # Username format (@username)
  info "Target type: Telegram username"
elif [[ "$TARGET" =~ ^[0-9]{6,}$ ]]; then
  # User ID format (numeric)
  info "Target type: Telegram user ID"
else
  error "Invalid target format. Expected user ID (123456789) or username (@username)"
fi

# Validate message is not empty
if [ -z "$MESSAGE" ]; then
  error "Message cannot be empty"
fi

# SSH to VM and send the message
info "Connecting to instance and sending message..."

# Try different possible CLI commands (OpenClaw CLI may vary)
# Attempt 1: openclaw message send telegram <target> <message>
SEND_CMD="openclaw message send telegram '$TARGET' '$MESSAGE'"

SEND_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "$SEND_CMD 2>&1" || echo "SEND_FAILED")

# Check if command succeeded
if [ "$SEND_OUTPUT" != "SEND_FAILED" ] && ! echo "$SEND_OUTPUT" | grep -qi "error\|failed\|not found"; then
  echo
  success "Message sent successfully!"
  echo
  echo -e "${BLUE}Details:${NC}"
  echo -e "  Instance: ${YELLOW}$INSTANCE_NAME${NC}"
  echo -e "  Target:   ${YELLOW}$TARGET${NC}"
  echo -e "  Message:  ${YELLOW}$MESSAGE${NC}"
  echo

  # Show output if verbose
  if [ -n "$SEND_OUTPUT" ] && [ "$SEND_OUTPUT" != "SEND_FAILED" ]; then
    echo -e "${BLUE}OpenClaw output:${NC}"
    echo "$SEND_OUTPUT"
    echo
  fi

  success "Delivery confirmed"
  echo
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  • Check instance status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
  echo -e "  • View gateway logs: ${YELLOW}ssh -i '$SSH_KEY' openclaw@$IP 'journalctl --user -u openclaw-gateway -n 20'${NC}"
  echo
  exit 0
fi

# If first attempt failed, try alternative command formats
info "Trying alternative command format..."

# Attempt 2: Using channel-specific command
SEND_CMD_ALT="openclaw channels send telegram '$TARGET' '$MESSAGE'"
SEND_OUTPUT_ALT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "$SEND_CMD_ALT 2>&1" || echo "SEND_FAILED")

if [ "$SEND_OUTPUT_ALT" != "SEND_FAILED" ] && ! echo "$SEND_OUTPUT_ALT" | grep -qi "error\|failed\|not found"; then
  echo
  success "Message sent successfully!"
  echo
  echo -e "${BLUE}Details:${NC}"
  echo -e "  Instance: ${YELLOW}$INSTANCE_NAME${NC}"
  echo -e "  Target:   ${YELLOW}$TARGET${NC}"
  echo -e "  Message:  ${YELLOW}$MESSAGE${NC}"
  echo
  success "Delivery confirmed"
  echo
  exit 0
fi

# Both attempts failed
echo
error "Failed to send message. Possible issues:
  • Target user is not paired with the bot
  • Telegram bot is not configured
  • Gateway is not running
  • OpenClaw CLI command format changed

Troubleshooting:
  1. Check paired users: ./scripts/approve-user.sh $INSTANCE_NAME --list
  2. Check gateway status: ./scripts/status.sh $INSTANCE_NAME
  3. View gateway logs:
     ssh -i '$SSH_KEY' openclaw@$IP 'journalctl --user -u openclaw-gateway -n 50'

Output from attempts:
$SEND_OUTPUT
$SEND_OUTPUT_ALT"
