#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy OpenClaw child instance with full identity stack
# =============================================================================
# Creates VM with:
#   - Telegram bot (token required)
#   - AgentMail inbox (auto-created)
#   - AgentMemory vault (auto-created)
#   - AMCP identity + Pinata checkpoints
#   - Self-healing watchdog
#
# Usage:
#   ./deploy.sh --name child-03 --bot-token "123:ABC..."
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
INSTANCES_DIR="$SCRIPT_DIR/instances"
CREDENTIALS_FILE="$INSTANCES_DIR/credentials.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check prerequisites
for tool in hcloud jq curl ssh-keygen openssl scp; do
  if ! command -v "$tool" &>/dev/null; then
    log_error "Missing required tool: $tool"
    exit 1
  fi
done

usage() {
  cat <<EOF
${BOLD}OpenClaw Deploy — Child Instance with Full Identity Stack${NC}

Usage: $0 --name <name> --bot-token <token> [OPTIONS]

${BOLD}Required:${NC}
  --name NAME             Instance name (e.g., child-03)
  --bot-token TOKEN       Telegram bot token from @BotFather

${BOLD}Optional:${NC}
  --region REGION         Hetzner region: nbg1, fsn1, hel1 (default: nbg1)
  --type TYPE             Server type (default: cx23)
  --checkpoint-interval   AMCP checkpoint interval (default: 1h)
  --help                  Show this help

${BOLD}Auto-created per child:${NC}
  - Telegram bot config (using provided token)
  - AgentMail inbox: <name>@agentmail.to
  - AgentMemory vault: <name>
  - AMCP identity with Pinata checkpoints
  - Self-healing watchdog

${BOLD}Example:${NC}
  # 1. Create bot via @BotFather, get token
  # 2. Deploy:
  ./deploy.sh --name child-03 --bot-token "7654321:AAF..."

Credentials: $CREDENTIALS_FILE
EOF
  exit 1
}

# =============================================================================
# Parse arguments
# =============================================================================
INSTANCE_NAME=""
BOT_TOKEN=""
REGION="nbg1"
SERVER_TYPE="cx23"
CHECKPOINT_INTERVAL="1h"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) INSTANCE_NAME="$2"; shift 2 ;;
    --bot-token) BOT_TOKEN="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --type) SERVER_TYPE="$2"; shift 2 ;;
    --checkpoint-interval) CHECKPOINT_INTERVAL="$2"; shift 2 ;;
    --help) usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

# Validate required args
[[ -z "$INSTANCE_NAME" ]] && { log_error "Missing --name"; usage; }
[[ -z "$BOT_TOKEN" ]] && { log_error "Missing --bot-token (create via @BotFather)"; usage; }

# Validate bot token format
if ! [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  log_error "Invalid bot token format. Should be: 123456789:AAxx..."
  exit 1
fi

# =============================================================================
# Load parent credentials
# =============================================================================
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  log_error "Credentials file not found: $CREDENTIALS_FILE"
  cat <<EOF
Create it with:
{
  "anthropic_api_key": "sk-ant-...",
  "parent_telegram_bot_token": "...",
  "parent_telegram_chat_id": "152099202",
  "agentmail_api_key": "am_...",
  "agentmemory_api_key": "...",
  "pinata_jwt": "...",
  "notify_email": "you@example.com"
}
EOF
  exit 1
fi

ANTHROPIC_API_KEY=$(jq -r '.anthropic_api_key // empty' "$CREDENTIALS_FILE")
PARENT_BOT_TOKEN=$(jq -r '.parent_telegram_bot_token // .telegram_bot_token // empty' "$CREDENTIALS_FILE")
PARENT_CHAT_ID=$(jq -r '.parent_telegram_chat_id // .telegram_chat_id // empty' "$CREDENTIALS_FILE")
AGENTMAIL_API_KEY=$(jq -r '.agentmail_api_key // empty' "$CREDENTIALS_FILE")
AGENTMEMORY_API_KEY=$(jq -r '.agentmemory_api_key // empty' "$CREDENTIALS_FILE")
PINATA_JWT=$(jq -r '.pinata_jwt // empty' "$CREDENTIALS_FILE")
NOTIFY_EMAIL=$(jq -r '.notify_email // empty' "$CREDENTIALS_FILE")

# Validate required credentials
[[ -z "$ANTHROPIC_API_KEY" ]] && { log_error "Missing anthropic_api_key"; exit 1; }
[[ -z "$PARENT_BOT_TOKEN" ]] && { log_error "Missing parent_telegram_bot_token"; exit 1; }
[[ -z "$PINATA_JWT" ]] && { log_error "Missing pinata_jwt (for AMCP)"; exit 1; }

# Generate unique tokens
GATEWAY_TOKEN=$(openssl rand -hex 24)
AMCP_SEED=$(openssl rand -hex 32)

# =============================================================================
# Verify bot token works
# =============================================================================
log_info "Verifying bot token..."
BOT_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe")
if [[ $(echo "$BOT_INFO" | jq -r '.ok') != "true" ]]; then
  log_error "Invalid bot token. Check with @BotFather"
  echo "$BOT_INFO" | jq '.'
  exit 1
fi
BOT_USERNAME=$(echo "$BOT_INFO" | jq -r '.result.username')
log_success "Bot verified: @${BOT_USERNAME}"

# =============================================================================
# Create VM
# =============================================================================
log_info "Creating instance: ${BOLD}${INSTANCE_NAME}${NC}"

# SSH key
SSH_KEY_PATH="$HOME/.ssh/openclaw_${INSTANCE_NAME}"
if [[ -f "$SSH_KEY_PATH" ]]; then
  log_warn "SSH key exists, reusing"
else
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "openclaw-${INSTANCE_NAME}" -q
  log_success "SSH key generated"
fi

# Upload to Hetzner
SSH_KEY_NAME="openclaw-${INSTANCE_NAME}"
hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null && hcloud ssh-key delete "$SSH_KEY_NAME" >/dev/null 2>&1 || true
hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_PATH}.pub" >/dev/null
log_success "SSH key uploaded"

# Create server
log_info "Creating server (~30s)..."
hcloud server create \
  --name "$INSTANCE_NAME" \
  --type "$SERVER_TYPE" \
  --image ubuntu-24.04 \
  --location "$REGION" \
  --ssh-key "$SSH_KEY_NAME" \
  >/dev/null

INSTANCE_IP=$(hcloud server ip "$INSTANCE_NAME")
log_success "Server: ${BOLD}${INSTANCE_IP}${NC}"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Wait for SSH
log_info "Waiting for SSH..."
SSH_READY=false
for i in {1..30}; do
  if ssh -i "$SSH_KEY_PATH" $SSH_OPTS -o ConnectTimeout=5 "root@${INSTANCE_IP}" "echo ok" &>/dev/null; then
    SSH_READY=true
    break
  fi
  sleep 2
done

if [[ "$SSH_READY" != "true" ]]; then
  log_error "SSH connection failed after 30 attempts to ${INSTANCE_IP}"
  log_error "Server may still be booting. Try: ssh -i ${SSH_KEY_PATH} root@${INSTANCE_IP}"
  exit 1
fi
log_success "SSH connection established"

# =============================================================================
# Notify parent
# =============================================================================
curl -s --connect-timeout 5 --max-time 10 \
  -X POST "https://api.telegram.org/bot${PARENT_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${PARENT_CHAT_ID}" \
  -d "text=🚀 Deploying ${INSTANCE_NAME} @ ${INSTANCE_IP}
Bot: @${BOT_USERNAME}
Region: ${REGION}" \
  -d "parse_mode=HTML" >/dev/null 2>&1 || log_warn "Failed to notify parent via Telegram"

# =============================================================================
# Upload and run master setup
# =============================================================================
log_info "Uploading setup script..."

TEMP_SCRIPT=$(mktemp)
trap "rm -f '$TEMP_SCRIPT'" EXIT
sed \
  -e "s|__INSTANCE_NAME__|${INSTANCE_NAME}|g" \
  -e "s|__INSTANCE_IP__|${INSTANCE_IP}|g" \
  -e "s|__ANTHROPIC_API_KEY__|${ANTHROPIC_API_KEY}|g" \
  -e "s|__BOT_TOKEN__|${BOT_TOKEN}|g" \
  -e "s|__BOT_USERNAME__|${BOT_USERNAME}|g" \
  -e "s|__PARENT_BOT_TOKEN__|${PARENT_BOT_TOKEN}|g" \
  -e "s|__PARENT_CHAT_ID__|${PARENT_CHAT_ID}|g" \
  -e "s|__AGENTMAIL_API_KEY__|${AGENTMAIL_API_KEY}|g" \
  -e "s|__AGENTMEMORY_API_KEY__|${AGENTMEMORY_API_KEY}|g" \
  -e "s|__PINATA_JWT__|${PINATA_JWT}|g" \
  -e "s|__NOTIFY_EMAIL__|${NOTIFY_EMAIL}|g" \
  -e "s|__GATEWAY_TOKEN__|${GATEWAY_TOKEN}|g" \
  -e "s|__AMCP_SEED__|${AMCP_SEED}|g" \
  -e "s|__CHECKPOINT_INTERVAL__|${CHECKPOINT_INTERVAL}|g" \
  "$SCRIPTS_DIR/master-setup.sh" > "$TEMP_SCRIPT"

scp -i "$SSH_KEY_PATH" $SSH_OPTS "$TEMP_SCRIPT" "root@${INSTANCE_IP}:/root/setup.sh"
rm -f "$TEMP_SCRIPT"

# Fire and forget
ssh -i "$SSH_KEY_PATH" $SSH_OPTS "root@${INSTANCE_IP}" \
  "chmod +x /root/setup.sh && nohup /root/setup.sh > /var/log/openclaw-setup.log 2>&1 &"

log_success "Setup launched (fire & forget)"

# =============================================================================
# Save metadata
# =============================================================================
mkdir -p "$INSTANCES_DIR/$INSTANCE_NAME"
cat > "$INSTANCES_DIR/$INSTANCE_NAME/metadata.json" << EOF
{
  "name": "${INSTANCE_NAME}",
  "ip": "${INSTANCE_IP}",
  "region": "${REGION}",
  "server_type": "${SERVER_TYPE}",
  "status": "deploying",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ssh_key_path": "${SSH_KEY_PATH}",
  "gateway_token": "${GATEWAY_TOKEN}",
  "bot_username": "${BOT_USERNAME}",
  "bot_token_hint": "${BOT_TOKEN:0:10}...",
  "email": "${INSTANCE_NAME}@agentmail.to",
  "amcp_enabled": true,
  "checkpoint_interval": "${CHECKPOINT_INTERVAL}"
}
EOF

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  🦞 Deploying: ${INSTANCE_NAME}${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}IP:${NC}        ${INSTANCE_IP}"
echo -e "  ${BOLD}Region:${NC}    ${REGION}"
echo -e "  ${BOLD}Bot:${NC}       @${BOT_USERNAME}"
echo -e "  ${BOLD}Email:${NC}     ${INSTANCE_NAME}@agentmail.to (creating...)"
echo -e "  ${BOLD}AMCP:${NC}      Enabled (checkpoints every ${CHECKPOINT_INTERVAL})"
echo ""
echo -e "  ${BOLD}SSH:${NC}       ssh -i ${SSH_KEY_PATH} root@${INSTANCE_IP}"
echo -e "  ${BOLD}Logs:${NC}      ssh ... 'tail -f /var/log/openclaw-setup.log'"
echo ""
echo -e "  ${CYAN}Child is setting up. Watch Telegram for updates.${NC}"
echo ""
