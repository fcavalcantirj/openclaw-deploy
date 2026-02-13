#!/usr/bin/env bash
set -euo pipefail

# setup-telegram-bot.sh - Configure Telegram bot token on deployed OpenClaw instance
# Usage: ./scripts/setup-telegram-bot.sh <instance-name> <bot-token>

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

warn() {
  echo -e "${YELLOW}WARNING: $1${NC}"
}

usage() {
  cat << EOF
Usage: $0 <instance-name> <bot-token>

Configure Telegram bot token on a deployed OpenClaw instance.

Arguments:
  instance-name    Name of the deployed instance
  bot-token        Telegram bot token from BotFather (format: 123456:ABC-DEF...)

Example:
  $0 mybot 123456789:ABCdefGHIjklMNOpqrsTUVwxyz

The script will:
1. Validate bot token format
2. Test bot token via Telegram API
3. Update OpenClaw config with bot token
4. Restart OpenClaw gateway
5. Output bot username for sharing with users
6. Show command to check pairing requests

EOF
  exit 1
}

# Validate arguments
if [ $# -lt 2 ]; then
  usage
fi

INSTANCE_NAME="$1"
BOT_TOKEN="$2"

# Validate bot token format
if ! [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  error "Invalid bot token format. Expected format: 123456:ABC-DEF..."
fi

# Check if instance exists
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  error "Instance '$INSTANCE_NAME' not found. Run ./scripts/list.sh to see available instances."
fi

# Load instance metadata
info "Loading instance metadata..."
IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key' "$METADATA_FILE")

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  error "Instance IP not found in metadata"
fi

if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
fi

echo
info "Configuring Telegram bot for instance: $INSTANCE_NAME"
echo

# Step 1: Validate bot token via Telegram API
info "Step 1/5: Validating bot token via Telegram API..."
BOT_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
BOT_OK=$(echo "$BOT_INFO" | jq -r '.ok')

if [ "$BOT_OK" != "true" ]; then
  error "Bot token validation failed. Please check the token and try again.\n$(echo "$BOT_INFO" | jq -r '.description')"
fi

BOT_USERNAME=$(echo "$BOT_INFO" | jq -r '.result.username')
BOT_FIRST_NAME=$(echo "$BOT_INFO" | jq -r '.result.first_name')
success "Bot token valid: @${BOT_USERNAME} (${BOT_FIRST_NAME})"
echo

# Step 2: Check if OpenClaw config exists
info "Step 2/5: Checking OpenClaw configuration..."
CONFIG_EXISTS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "openclaw@$IP" "test -f ~/.openclaw/openclaw.json && echo 'exists' || echo 'missing'" 2>/dev/null || echo "ssh_failed")

if [ "$CONFIG_EXISTS" = "ssh_failed" ]; then
  error "Cannot connect to instance via SSH. Check that the instance is running."
fi

if [ "$CONFIG_EXISTS" = "missing" ]; then
  error "OpenClaw config not found on instance. Run setup-openclaw.sh first."
fi

success "OpenClaw config found"
echo

# Step 3: Update OpenClaw config with bot token
info "Step 3/5: Updating OpenClaw config with bot token..."

# Use jq to update the config file safely
UPDATE_CONFIG=$(cat << 'EOF'
set -euo pipefail
CONFIG_FILE=~/.openclaw/openclaw.json
BACKUP_FILE=~/.openclaw/openclaw.json.backup-$(date +%s)

# Backup current config
cp "$CONFIG_FILE" "$BACKUP_FILE"

# Update bot token using jq
jq --arg token "$1" '.telegram.botToken = $token' "$CONFIG_FILE" > "$CONFIG_FILE.tmp"
mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

echo "Config updated successfully"
echo "Backup saved to: $BACKUP_FILE"
EOF
)

UPDATE_RESULT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "openclaw@$IP" "bash -s -- '$BOT_TOKEN'" <<< "$UPDATE_CONFIG" 2>&1) || {
  error "Failed to update config:\n$UPDATE_RESULT"
}

success "Bot token configured"
echo

# Step 4: Restart OpenClaw gateway
info "Step 4/5: Restarting OpenClaw gateway..."

RESTART_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "openclaw@$IP" "systemctl --user restart openclaw-gateway && sleep 2 && systemctl --user is-active openclaw-gateway" 2>&1) || {
  warn "Gateway restart may have failed. Output:\n$RESTART_OUTPUT"
}

if echo "$RESTART_OUTPUT" | grep -q "active"; then
  success "Gateway restarted successfully"
else
  warn "Gateway status unclear. Check manually with: ./scripts/status.sh $INSTANCE_NAME"
fi
echo

# Step 5: Update metadata with bot username
info "Step 5/5: Updating instance metadata..."
jq --arg bot "@${BOT_USERNAME}" '.telegram_bot = $bot' "$METADATA_FILE" > "$METADATA_FILE.tmp"
mv "$METADATA_FILE.tmp" "$METADATA_FILE"
success "Metadata updated"
echo

# Success summary
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Telegram Bot Configuration Complete${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo
echo -e "${BLUE}Bot Details:${NC}"
echo -e "  Username:     ${GREEN}@${BOT_USERNAME}${NC}"
echo -e "  Display Name: ${BOT_FIRST_NAME}"
echo -e "  Instance:     ${INSTANCE_NAME}"
echo
echo -e "${BLUE}Next Steps:${NC}"
echo -e "  1. Share bot username ${GREEN}@${BOT_USERNAME}${NC} with users"
echo -e "  2. Users should message the bot on Telegram"
echo -e "  3. Check for pairing requests:"
echo -e "     ${YELLOW}./scripts/list-pairing-requests.sh ${INSTANCE_NAME}${NC}"
echo -e "  4. Approve pairing requests:"
echo -e "     ${YELLOW}./scripts/approve-user.sh ${INSTANCE_NAME} <pairing-code>${NC}"
echo
echo -e "${BLUE}Quick Commands:${NC}"
echo -e "  Check gateway status:"
echo -e "    ${YELLOW}./scripts/status.sh ${INSTANCE_NAME}${NC}"
echo -e "  View gateway logs:"
echo -e "    ${YELLOW}ssh -i ${SSH_KEY} openclaw@${IP} 'journalctl --user -u openclaw-gateway -n 20'${NC}"
echo -e "  Send test message:"
echo -e "    ${YELLOW}./scripts/send-message.sh ${INSTANCE_NAME} <user-id> 'Hello!'${NC}"
echo
