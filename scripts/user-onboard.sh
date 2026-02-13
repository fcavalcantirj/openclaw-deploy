#!/usr/bin/env bash
set -euo pipefail

# user-onboard.sh - Complete user onboarding flow for OpenClaw Telegram bot
# Usage: ./scripts/user-onboard.sh <instance-name> <bot-token> [--auto-approve]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

warn() {
  echo -e "${YELLOW}WARNING: $1${NC}"
}

step_header() {
  echo
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}$1${NC}"
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
  echo
}

usage() {
  cat << EOF
Usage: $0 <instance-name> <bot-token> [--auto-approve]

Complete user onboarding flow for OpenClaw Telegram bot.

This script orchestrates the full process:
  1. Configure Telegram bot token
  2. Display bot username for user to message
  3. Wait for user to send pairing request
  4. Show pending pairing requests
  5. Approve pairing (manual or auto)

Arguments:
  instance-name    Name of the deployed instance
  bot-token        Telegram bot token from BotFather
  --auto-approve   Automatically approve first pending pairing request (optional)

Examples:
  # Manual approval workflow
  $0 mybot 123456789:ABCdefGHIjklMNOpqrsTUVwxyz

  # Auto-approve first pairing request (for single-user setup)
  $0 mybot 123456789:ABCdefGHIjklMNOpqrsTUVwxyz --auto-approve

Workflow:
  1. Sets up bot token on instance
  2. Shows bot username to share with user
  3. Waits for user to message bot
  4. Lists pending pairing requests
  5. Approves pairing (manual code entry or auto)

EOF
  exit 1
}

# Validate arguments
if [ $# -lt 2 ]; then
  usage
fi

INSTANCE_NAME="$1"
BOT_TOKEN="$2"
AUTO_APPROVE=false

if [ $# -eq 3 ] && [ "$3" = "--auto-approve" ]; then
  AUTO_APPROVE=true
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

# Welcome banner
clear
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║                                                           ║${NC}"
echo -e "${GREEN}${BOLD}║          OpenClaw User Onboarding Wizard                  ║${NC}"
echo -e "${GREEN}${BOLD}║                                                           ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
echo
echo -e "${BLUE}Instance:${NC}     $INSTANCE_NAME"
echo -e "${BLUE}IP Address:${NC}   $IP"
echo -e "${BLUE}Mode:${NC}         $([ "$AUTO_APPROVE" = true ] && echo "Auto-approve" || echo "Manual approval")"
echo
read -p "Press Enter to start onboarding process..."

# ═══════════════════════════════════════════════════════════
# STEP 1: Configure Bot Token
# ═══════════════════════════════════════════════════════════
step_header "STEP 1: Configure Telegram Bot"

info "Running setup-telegram-bot.sh..."
echo

if ! "$SCRIPT_DIR/setup-telegram-bot.sh" "$INSTANCE_NAME" "$BOT_TOKEN"; then
  error "Failed to configure bot token. Check the error above and try again."
fi

# Extract bot username from metadata (updated by setup-telegram-bot.sh)
BOT_USERNAME=$(jq -r '.telegram_bot' "$METADATA_FILE")

if [ -z "$BOT_USERNAME" ] || [ "$BOT_USERNAME" = "null" ]; then
  error "Bot username not found in metadata after setup"
fi

success "Bot configured successfully: $BOT_USERNAME"

# ═══════════════════════════════════════════════════════════
# STEP 2: User Action Required
# ═══════════════════════════════════════════════════════════
step_header "STEP 2: User Action Required"

echo -e "${YELLOW}${BOLD}ACTION NEEDED:${NC}"
echo
echo -e "  Share this bot username with your user:"
echo -e "  ${GREEN}${BOLD}${BOT_USERNAME}${NC}"
echo
echo -e "  The user should:"
echo -e "    1. Open Telegram"
echo -e "    2. Search for ${GREEN}${BOT_USERNAME}${NC}"
echo -e "    3. Click START or send any message"
echo
echo -e "${BLUE}The bot will generate a 6-digit pairing code that needs approval.${NC}"
echo

read -p "Press Enter once the user has messaged the bot..."

# ═══════════════════════════════════════════════════════════
# STEP 3: Check for Pairing Requests
# ═══════════════════════════════════════════════════════════
step_header "STEP 3: Check for Pairing Requests"

info "Checking for pending pairing requests..."
echo

# Get pending pairing requests
PAIRING_LIST=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "openclaw pairing list telegram 2>&1" || echo "FAILED")

if [ "$PAIRING_LIST" = "FAILED" ]; then
  error "Cannot connect to instance or openclaw command failed"
fi

echo "$PAIRING_LIST"
echo

# Check if there are pending requests
if echo "$PAIRING_LIST" | grep -qi "no pending\|empty\|none found"; then
  warn "No pending pairing requests found."
  echo
  echo -e "${YELLOW}Possible reasons:${NC}"
  echo -e "  • User hasn't messaged the bot yet"
  echo -e "  • Pairing request already approved/expired"
  echo -e "  • Gateway not receiving Telegram updates"
  echo
  echo -e "${BLUE}Next steps:${NC}"
  echo -e "  1. Ask user to message ${BOT_USERNAME} again"
  echo -e "  2. Check gateway logs: ${YELLOW}ssh -i $SSH_KEY openclaw@$IP 'journalctl --user -u openclaw-gateway -n 50'${NC}"
  echo -e "  3. Verify bot token: ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
  echo
  exit 1
fi

# ═══════════════════════════════════════════════════════════
# STEP 4: Approve Pairing Request
# ═══════════════════════════════════════════════════════════
step_header "STEP 4: Approve Pairing Request"

if [ "$AUTO_APPROVE" = true ]; then
  info "Auto-approve mode enabled. Extracting first pairing code..."
  echo

  # Extract first 6-digit code from output
  PAIRING_CODE=$(echo "$PAIRING_LIST" | grep -oP '\b[0-9]{6}\b' | head -1)

  if [ -z "$PAIRING_CODE" ]; then
    error "Could not extract pairing code from output. Try manual approval."
  fi

  info "Found pairing code: $PAIRING_CODE"
  echo

  read -p "Press Enter to approve this pairing code (or Ctrl+C to cancel)..."

else
  # Manual mode - ask for pairing code
  echo -e "${YELLOW}Enter the 6-digit pairing code from the list above:${NC}"
  read -p "Pairing code: " PAIRING_CODE
  echo

  # Validate format
  if ! [[ "$PAIRING_CODE" =~ ^[0-9]{6}$ ]]; then
    error "Invalid pairing code format. Expected 6 digits, got: $PAIRING_CODE"
  fi
fi

info "Approving pairing code: $PAIRING_CODE"
echo

# Run approval
if ! "$SCRIPT_DIR/approve-user.sh" "$INSTANCE_NAME" "$PAIRING_CODE"; then
  error "Failed to approve pairing request. Check the error above."
fi

# ═══════════════════════════════════════════════════════════
# SUCCESS SUMMARY
# ═══════════════════════════════════════════════════════════
step_header "Onboarding Complete! 🎉"

echo -e "${GREEN}${BOLD}User has been successfully onboarded!${NC}"
echo
echo -e "${BLUE}What's Next:${NC}"
echo
echo -e "  ${GREEN}✓${NC} Bot configured: ${BOT_USERNAME}"
echo -e "  ${GREEN}✓${NC} User paired and ready to chat"
echo -e "  ${GREEN}✓${NC} Gateway running on instance: $INSTANCE_NAME"
echo
echo -e "${BLUE}Useful Commands:${NC}"
echo
echo -e "  • Check instance status:"
echo -e "    ${YELLOW}./scripts/status.sh $INSTANCE_NAME${NC}"
echo
echo -e "  • Send message to user:"
echo -e "    ${YELLOW}./scripts/send-message.sh $INSTANCE_NAME <user-id> 'Welcome!'${NC}"
echo
echo -e "  • View gateway logs:"
echo -e "    ${YELLOW}ssh -i $SSH_KEY openclaw@$IP 'journalctl --user -u openclaw-gateway -f'${NC}"
echo
echo -e "  • List all pairing requests:"
echo -e "    ${YELLOW}./scripts/approve-user.sh $INSTANCE_NAME --list${NC}"
echo
echo -e "${GREEN}${BOLD}Happy chatting! 🤖${NC}"
echo
