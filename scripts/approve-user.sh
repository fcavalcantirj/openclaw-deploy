#!/usr/bin/env bash
set -euo pipefail

# approve-user.sh - Approve Telegram pairing request for OpenClaw instance
# Usage: ./scripts/approve-user.sh <instance-name> <pairing-code>

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
Usage: $0 <instance-name> <pairing-code>
       $0 <instance-name> --list

Approve Telegram pairing requests for an OpenClaw instance.

Arguments:
  instance-name    Name of the deployed instance
  pairing-code     The 6-digit pairing code from the user
  --list           List pending pairing requests instead of approving

Examples:
  $0 mybot 123456
  $0 mybot --list

EOF
  exit 1
}

# Validate arguments
if [ $# -lt 1 ]; then
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

# Handle --list flag
if [ $# -eq 2 ] && [ "$2" = "--list" ]; then
  info "Checking pairing requests for instance: $INSTANCE_NAME"
  echo

  # SSH to VM and run openclaw pairing list command
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "openclaw@$IP" "openclaw pairing list telegram"; then
    error "Cannot connect to instance or openclaw command failed"
  fi

  echo
  echo -e "${BLUE}To approve a pairing request:${NC}"
  echo -e "  ${YELLOW}$0 $INSTANCE_NAME <pairing-code>${NC}"
  echo
  exit 0
fi

# Validate pairing code
if [ $# -lt 2 ]; then
  error "Pairing code required. Usage: $0 $INSTANCE_NAME <pairing-code>"
fi

PAIRING_CODE="$2"

# Validate pairing code format (should be 6 digits)
if ! [[ "$PAIRING_CODE" =~ ^[0-9]{6}$ ]]; then
  error "Invalid pairing code format. Expected 6 digits, got: $PAIRING_CODE"
fi

echo
info "Approving pairing request for instance: $INSTANCE_NAME"
info "Pairing code: $PAIRING_CODE"
echo

# SSH to VM and approve the pairing request
info "Connecting to instance..."
APPROVAL_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw pairing approve telegram $PAIRING_CODE 2>&1" || echo "FAILED")

if [ "$APPROVAL_OUTPUT" = "FAILED" ]; then
  error "Cannot connect to instance or openclaw command failed"
fi

# Check if approval succeeded
if echo "$APPROVAL_OUTPUT" | grep -qi "approved\|success"; then
  success "Pairing request approved successfully!"
  echo
  echo "$APPROVAL_OUTPUT"
  echo
  success "User is now paired and can use the bot"
  echo
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  • Send a message to the user: ${YELLOW}./scripts/send-message.sh $INSTANCE_NAME <user-id> 'Welcome!'${NC}"
  echo -e "  • Check instance status: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
  echo
elif echo "$APPROVAL_OUTPUT" | grep -qi "not found\|invalid\|expired"; then
  error "Pairing code not found or invalid. Check pending requests with: $0 $INSTANCE_NAME --list"
else
  echo -e "${YELLOW}⚠ Approval status unclear. Output:${NC}"
  echo "$APPROVAL_OUTPUT"
  echo
  info "Verify pairing status by messaging the bot or checking gateway logs"
  echo
fi
