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
  --parent-solvr-name NAME  Override parent Solvr agent name (auto-detected from SOLVR_API_KEY)
  --model MODEL           Default model (default: anthropic/claude-sonnet-4-5-20250929)
  --fallback-models JSON  Fallback model chain as JSON array
  --skills LIST           Space-separated skill list to install
  --solvr-enabled         Enable Solvr IPFS pinning (requires SOLVR_API_KEY in credentials)
  --parent-telegram-token TOKEN  Override parent Telegram bot token
  --parent-chat-id ID     Override parent Telegram chat ID
  --parent-email EMAIL    Override parent notification email
  --help                  Show this help

${BOLD}Auto-created per child:${NC}
  - Telegram bot config (using provided token)
  - AgentMail inbox: <name>@agentmail.to
  - AgentMemory vault: <name>
  - AMCP identity with Pinata checkpoints
  - Self-healing watchdog
  - Solvr child agent (if --solvr-enabled and SOLVR_API_KEY set)

${BOLD}Example:${NC}
  # 1. Create bot via @BotFather, get token
  # 2. Deploy:
  ./deploy.sh --name child-03 --bot-token "7654321:AAF..."

  # With Solvr IPFS pinning:
  ./deploy.sh --name child-03 --bot-token "7654321:AAF..." --solvr-enabled

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
PARENT_SOLVR_NAME=""
DEFAULT_MODEL="anthropic/claude-sonnet-4-5-20250929"
FALLBACK_MODELS='["anthropic/claude-opus-4-6","anthropic/claude-haiku-4-5-20251001"]'
SKILLS_LIST=""
SOLVR_ENABLED=false
FLAG_PARENT_TELEGRAM_TOKEN=""
FLAG_PARENT_CHAT_ID=""
FLAG_PARENT_EMAIL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) INSTANCE_NAME="$2"; shift 2 ;;
    --bot-token) BOT_TOKEN="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --type) SERVER_TYPE="$2"; shift 2 ;;
    --checkpoint-interval) CHECKPOINT_INTERVAL="$2"; shift 2 ;;
    --model) DEFAULT_MODEL="$2"; shift 2 ;;
    --fallback-models) FALLBACK_MODELS="$2"; shift 2 ;;
    --skills) SKILLS_LIST="$2"; shift 2 ;;
    --solvr-enabled) SOLVR_ENABLED=true; shift ;;
    --parent-solvr-name) PARENT_SOLVR_NAME="$2"; shift 2 ;;
    --parent-telegram-token) FLAG_PARENT_TELEGRAM_TOKEN="$2"; shift 2 ;;
    --parent-chat-id) FLAG_PARENT_CHAT_ID="$2"; shift 2 ;;
    --parent-email) FLAG_PARENT_EMAIL="$2"; shift 2 ;;
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
  "notify_email": "you@example.com",
  "solvr_api_key": "solvr_..."
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
SOLVR_API_KEY=$(jq -r '.solvr_api_key // empty' "$CREDENTIALS_FILE")
OPENAI_API_KEY=$(jq -r '.openai_api_key // empty' "$CREDENTIALS_FILE")

# Apply flag overrides (flags take priority over credentials.json)
[[ -n "$FLAG_PARENT_TELEGRAM_TOKEN" ]] && PARENT_BOT_TOKEN="$FLAG_PARENT_TELEGRAM_TOKEN"
[[ -n "$FLAG_PARENT_CHAT_ID" ]] && PARENT_CHAT_ID="$FLAG_PARENT_CHAT_ID"
[[ -n "$FLAG_PARENT_EMAIL" ]] && NOTIFY_EMAIL="$FLAG_PARENT_EMAIL"

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
# Register child Solvr account (protocol-08 naming)
# =============================================================================
SOLVR_API_URL="${SOLVR_API_URL:-https://api.solvr.dev/v1}"
CHILD_SOLVR_API_KEY=""
CHILD_SOLVR_NAME=""

if [[ "$SOLVR_ENABLED" == true ]]; then
  # --solvr-enabled requires SOLVR_API_KEY
  if [[ -z "$SOLVR_API_KEY" ]]; then
    log_error "--solvr-enabled requires solvr_api_key in credentials.json or SOLVR_API_KEY env var"
    exit 1
  fi
  log_info "Registering child Solvr account (--solvr-enabled)..."

  # Step 1: Resolve parent name (auto-detect from /v1/me or use --parent-solvr-name flag)
  if [[ -z "$PARENT_SOLVR_NAME" ]]; then
    PARENT_ME_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 \
      -H "Authorization: Bearer ${SOLVR_API_KEY}" \
      -H "Accept: application/json" \
      "${SOLVR_API_URL}/me" 2>&1 || echo '{}')
    PARENT_SOLVR_NAME=$(echo "$PARENT_ME_RESPONSE" | jq -r '.data.id // .data.name // empty' 2>/dev/null)
    if [[ -z "$PARENT_SOLVR_NAME" ]]; then
      log_error "Could not auto-detect parent Solvr name from /v1/me"
      log_error "Pass --parent-solvr-name explicitly or check SOLVR_API_KEY"
      exit 1
    fi
  fi
  log_success "Parent Solvr name: ${PARENT_SOLVR_NAME}"

  # Step 2: Build child name — deterministic protocol-08 naming
  # Format: {parent}_child_{instance} — lowercase, alphanum+underscore, max 50 chars
  SANITIZED_INSTANCE=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_' | tr -cd 'a-z0-9_')
  CHILD_SOLVR_NAME="${PARENT_SOLVR_NAME}_child_${SANITIZED_INSTANCE}"

  # Truncate to 50 chars (Solvr agent ID max)
  CHILD_SOLVR_NAME="${CHILD_SOLVR_NAME:0:50}"

  # Validate: must be lowercase, alphanum+underscore only
  if ! [[ "$CHILD_SOLVR_NAME" =~ ^[a-z0-9_]+$ ]]; then
    log_error "Invalid child Solvr name: ${CHILD_SOLVR_NAME}"
    log_error "Must be lowercase alphanumeric + underscore only"
    exit 1
  fi
  log_info "Child Solvr name: ${CHILD_SOLVR_NAME}"

  # Step 3: Register child agent via Solvr API
  REGISTER_PAYLOAD=$(jq -n \
    --arg id "$CHILD_SOLVR_NAME" \
    --arg name "$CHILD_SOLVR_NAME" \
    --arg desc "OpenClaw child instance: ${INSTANCE_NAME}" \
    --argjson specialties '["openclaw", "gateway", "self-healing"]' \
    '{id: $id, display_name: $name, bio: $desc, specialties: $specialties}')

  REGISTER_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 \
    -X POST "${SOLVR_API_URL}/agents" \
    -H "Authorization: Bearer ${SOLVR_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REGISTER_PAYLOAD" 2>&1 || echo '{}')

  CHILD_SOLVR_API_KEY=$(echo "$REGISTER_RESPONSE" | jq -r '.data.api_key // empty' 2>/dev/null)

  if [[ -z "$CHILD_SOLVR_API_KEY" ]]; then
    # Check if already registered (duplicate error)
    ERROR_CODE=$(echo "$REGISTER_RESPONSE" | jq -r '.error.code // empty' 2>/dev/null)
    if [[ "$ERROR_CODE" == "DUPLICATE_CONTENT" || "$ERROR_CODE" == "VALIDATION_ERROR" ]]; then
      log_warn "Child Solvr agent may already exist: ${CHILD_SOLVR_NAME}"
      log_warn "Continuing without child API key — set manually if needed"
    else
      log_warn "Solvr registration failed (non-fatal): $(echo "$REGISTER_RESPONSE" | jq -r '.error.message // "unknown"' 2>/dev/null)"
    fi
  else
    log_success "Child Solvr agent registered: ${CHILD_SOLVR_NAME}"

    # Step 4: Verify child can call GET /v1/me with its own key
    CHILD_ME_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 \
      -H "Authorization: Bearer ${CHILD_SOLVR_API_KEY}" \
      -H "Accept: application/json" \
      "${SOLVR_API_URL}/me" 2>&1 || echo '{}')
    CHILD_VERIFIED_NAME=$(echo "$CHILD_ME_RESPONSE" | jq -r '.data.id // .data.name // empty' 2>/dev/null)
    if [[ -n "$CHILD_VERIFIED_NAME" ]]; then
      log_success "Child Solvr verified: ${CHILD_VERIFIED_NAME}"
    else
      log_warn "Child Solvr verification skipped (API may take time to propagate)"
    fi
  fi
else
  log_info "Solvr disabled (use --solvr-enabled to opt in)"
fi

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
  -e "s|__CHILD_SOLVR_API_KEY__|${CHILD_SOLVR_API_KEY}|g" \
  -e "s|__PARENT_SOLVR_NAME__|${PARENT_SOLVR_NAME}|g" \
  -e "s|__DEFAULT_MODEL__|${DEFAULT_MODEL}|g" \
  -e "s|__FALLBACK_MODELS__|${FALLBACK_MODELS}|g" \
  -e "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|g" \
  -e "s|__SKILLS_LIST__|${SKILLS_LIST}|g" \
  -e "s|__SOLVR_ENABLED__|${SOLVR_ENABLED}|g" \
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
METADATA_FILE="$INSTANCES_DIR/$INSTANCE_NAME/metadata.json"
jq -n \
  --arg name "$INSTANCE_NAME" \
  --arg ip "$INSTANCE_IP" \
  --arg region "$REGION" \
  --arg server_type "$SERVER_TYPE" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg ssh_key_path "$SSH_KEY_PATH" \
  --arg gateway_token "$GATEWAY_TOKEN" \
  --arg bot_username "$BOT_USERNAME" \
  --arg bot_token_hint "${BOT_TOKEN:0:10}..." \
  --arg email "${INSTANCE_NAME}@agentmail.to" \
  --arg checkpoint_interval "$CHECKPOINT_INTERVAL" \
  --arg parent_solvr_name "$PARENT_SOLVR_NAME" \
  --arg child_solvr_name "$CHILD_SOLVR_NAME" \
  --arg child_solvr_api_key_hint "${CHILD_SOLVR_API_KEY:0:12}..." \
  --arg parent_telegram_token "$PARENT_BOT_TOKEN" \
  --arg parent_chat_id "$PARENT_CHAT_ID" \
  --arg parent_email "$NOTIFY_EMAIL" \
  '{
    name: $name,
    ip: $ip,
    region: $region,
    server_type: $server_type,
    status: "deploying",
    created_at: $created_at,
    ssh_key_path: $ssh_key_path,
    gateway_token: $gateway_token,
    bot_username: $bot_username,
    bot_token_hint: $bot_token_hint,
    email: $email,
    amcp_enabled: true,
    checkpoint_interval: $checkpoint_interval,
    parent_solvr_name: $parent_solvr_name,
    child_solvr_name: $child_solvr_name,
    child_solvr_api_key_hint: $child_solvr_api_key_hint,
    parent_telegram_token: $parent_telegram_token,
    parent_chat_id: $parent_chat_id,
    parent_email: $parent_email
  }' > "$METADATA_FILE"

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
echo -e "  ${BOLD}Model:${NC}     ${DEFAULT_MODEL}"
echo -e "  ${BOLD}AMCP:${NC}      Enabled (checkpoints every ${CHECKPOINT_INTERVAL})"
if [[ -n "$CHILD_SOLVR_NAME" ]]; then
  echo -e "  ${BOLD}Solvr:${NC}     ${CHILD_SOLVR_NAME}"
fi
echo ""
echo -e "  ${BOLD}SSH:${NC}       ssh -i ${SSH_KEY_PATH} root@${INSTANCE_IP}"
echo -e "  ${BOLD}Logs:${NC}      ssh ... 'tail -f /var/log/openclaw-setup.log'"
echo ""
echo -e "  ${CYAN}Child is setting up. Watch Telegram for updates.${NC}"
echo ""
