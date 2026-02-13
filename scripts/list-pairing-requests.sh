#!/usr/bin/env bash
set -euo pipefail

# list-pairing-requests.sh - List pending Telegram pairing requests
# Usage: ./scripts/list-pairing-requests.sh <instance-name>

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

List pending Telegram pairing requests for an OpenClaw instance.

Arguments:
  instance-name    Name of the deployed instance

Example:
  $0 mybot

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

echo
info "Checking pairing requests for instance: $INSTANCE_NAME"
echo

# SSH to VM and run openclaw pairing list command
PAIRING_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw pairing list telegram 2>&1" || echo "FAILED")

if [ "$PAIRING_OUTPUT" = "FAILED" ]; then
  error "Cannot connect to instance or openclaw command failed"
fi

# Check if there are any pending requests
if echo "$PAIRING_OUTPUT" | grep -qi "no pending"; then
  info "No pending pairing requests"
  echo
  echo -e "${BLUE}To approve users:${NC}"
  echo -e "  1. Users must message the bot first"
  echo -e "  2. They will receive a pairing code"
  echo -e "  3. Approve with: ${YELLOW}./scripts/approve-user.sh $INSTANCE_NAME <code>${NC}"
  echo
  exit 0
fi

# Display pairing requests
echo -e "${GREEN}Pending Pairing Requests:${NC}"
echo "$PAIRING_OUTPUT"
echo
echo -e "${BLUE}To approve a pairing request:${NC}"
echo -e "  ${YELLOW}./scripts/approve-user.sh $INSTANCE_NAME <pairing-code>${NC}"
echo
