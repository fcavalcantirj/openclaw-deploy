#!/usr/bin/env bash
# =============================================================================
# master-setup.sh — Child OpenClaw with full identity stack
# =============================================================================
# Creates:
#   - OpenClaw installation
#   - Telegram bot config
#   - AgentMail inbox
#   - AgentMemory vault
#   - AMCP identity + first checkpoint
#   - Self-healing watchdog
# =============================================================================
set -euo pipefail

# Credentials (replaced by deploy.sh)
INSTANCE_NAME="__INSTANCE_NAME__"
INSTANCE_IP="__INSTANCE_IP__"
ANTHROPIC_API_KEY="__ANTHROPIC_API_KEY__"
BOT_TOKEN="__BOT_TOKEN__"
BOT_USERNAME="__BOT_USERNAME__"
PARENT_BOT_TOKEN="__PARENT_BOT_TOKEN__"
PARENT_CHAT_ID="__PARENT_CHAT_ID__"
AGENTMAIL_API_KEY="__AGENTMAIL_API_KEY__"
AGENTMEMORY_API_KEY="__AGENTMEMORY_API_KEY__"
PINATA_JWT="__PINATA_JWT__"
NOTIFY_EMAIL="__NOTIFY_EMAIL__"
GATEWAY_TOKEN="__GATEWAY_TOKEN__"
AMCP_SEED="__AMCP_SEED__"
CHECKPOINT_INTERVAL="__CHECKPOINT_INTERVAL__"

LOG_FILE="/var/log/openclaw-setup.log"
CHILD_EMAIL="${INSTANCE_NAME}@agentmail.to"

# =============================================================================
# Notification functions
# =============================================================================

notify_parent() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${PARENT_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${PARENT_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=HTML" \
    --connect-timeout 5 --max-time 10 >/dev/null 2>&1 || true
}

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*" | tee -a "$LOG_FILE"
}

notify() {
  log "$*"
  notify_parent "🦞 <b>${INSTANCE_NAME}</b>: $*"
}

fail() {
  log "FAILED: $*"
  notify_parent "❌ <b>${INSTANCE_NAME}</b> FAILED: $*"
  exit 1
}

# =============================================================================
# Main setup
# =============================================================================

main() {
  log "=========================================="
  log "OpenClaw Child Setup: ${INSTANCE_NAME}"
  log "IP: ${INSTANCE_IP}"
  log "Bot: @${BOT_USERNAME}"
  log "=========================================="
  
  notify "🚀 Starting deployment..."

  # -------------------------------------------------------------------------
  # Step 1: System setup
  # -------------------------------------------------------------------------
  notify "📦 Updating system..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq curl git jq python3 python3-pip

  # -------------------------------------------------------------------------
  # Step 2: Node.js
  # -------------------------------------------------------------------------
  notify "⬢ Installing Node.js..."
  if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
  fi
  log "Node: $(node -v)"

  # -------------------------------------------------------------------------
  # Step 3: Create openclaw user
  # -------------------------------------------------------------------------
  notify "👤 Creating user..."
  if ! id openclaw &>/dev/null; then
    useradd -m -s /bin/bash openclaw
    echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw
  fi
  mkdir -p /home/openclaw/.ssh
  cp /root/.ssh/authorized_keys /home/openclaw/.ssh/ 2>/dev/null || true
  chown -R openclaw:openclaw /home/openclaw/.ssh
  chmod 700 /home/openclaw/.ssh

  # -------------------------------------------------------------------------
  # Step 4: Install OpenClaw
  # -------------------------------------------------------------------------
  notify "🦞 Installing OpenClaw..."
  npm install -g openclaw
  log "OpenClaw: $(openclaw --version)"

  # -------------------------------------------------------------------------
  # Step 5: Create AgentMail inbox
  # -------------------------------------------------------------------------
  notify "📧 Creating email inbox..."
  if [[ -n "$AGENTMAIL_API_KEY" ]]; then
    # Try to create inbox (may already exist)
    INBOX_RESULT=$(curl -s -X POST "https://api.agentmail.to/v1/inboxes" \
      -H "Authorization: Bearer ${AGENTMAIL_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"username\": \"${INSTANCE_NAME}\"}" 2>/dev/null || echo '{}')
    log "AgentMail inbox: ${CHILD_EMAIL}"
  fi

  # -------------------------------------------------------------------------
  # Step 6: Create AgentMemory vault
  # -------------------------------------------------------------------------
  notify "🧠 Creating memory vault..."
  if [[ -n "$AGENTMEMORY_API_KEY" ]]; then
    # AgentMemory vault will be created on first use
    log "AgentMemory: ${INSTANCE_NAME} vault configured"
  fi

  # -------------------------------------------------------------------------
  # Step 7: Initialize AMCP identity
  # -------------------------------------------------------------------------
  notify "🔐 Initializing AMCP..."
  AMCP_DIR="/home/openclaw/.amcp"
  mkdir -p "$AMCP_DIR"
  
  # Generate deterministic identity from seed
  AMCP_AID=$(echo -n "${AMCP_SEED}" | sha256sum | cut -c1-44)
  
  cat > "$AMCP_DIR/identity.json" << AMCPEOF
{
  "aid": "${AMCP_AID}",
  "instance": "${INSTANCE_NAME}",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "pinata_jwt": "${PINATA_JWT}",
  "checkpoint_interval": "${CHECKPOINT_INTERVAL}",
  "deaths": 0,
  "last_checkpoint": null
}
AMCPEOF
  chown -R openclaw:openclaw "$AMCP_DIR"
  log "AMCP AID: ${AMCP_AID:0:20}..."

  # -------------------------------------------------------------------------
  # Step 8: Configure OpenClaw
  # -------------------------------------------------------------------------
  notify "⚙️ Configuring OpenClaw..."
  
  su - openclaw -c "mkdir -p ~/.openclaw/agents/main/agent ~/.openclaw/workspace"
  
  # Main config with Telegram
  su - openclaw -c "cat > ~/.openclaw/openclaw.json" << CONFIGEOF
{
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "port": 18789,
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "${BOT_TOKEN}",
      "dmPolicy": "pairing"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/openclaw/.openclaw/workspace",
      "heartbeat": {
        "every": "2h"
      }
    }
  }
}
CONFIGEOF

  # Auth profiles
  su - openclaw -c "cat > ~/.openclaw/agents/main/agent/auth-profiles.json" << AUTHEOF
{
  "version": 1,
  "profiles": {
    "anthropic:token": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "${ANTHROPIC_API_KEY}"
    }
  },
  "order": {"anthropic": ["anthropic:token"]}
}
AUTHEOF

  su - openclaw -c "chmod 600 ~/.openclaw/openclaw.json ~/.openclaw/agents/main/agent/auth-profiles.json"

  # -------------------------------------------------------------------------
  # Step 9: Create watchdog for self-healing
  # -------------------------------------------------------------------------
  notify "🛡️ Setting up watchdog..."
  
  cat > /usr/local/bin/openclaw-watchdog << 'WATCHDOGEOF'
#!/usr/bin/env bash
# OpenClaw Self-Healing Watchdog
set -euo pipefail

AMCP_FILE="/home/openclaw/.amcp/identity.json"
LOG="/var/log/openclaw-watchdog.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Check gateway
if ! systemctl is-active --quiet openclaw-gateway; then
  log "Gateway down! Attempting resurrection..."
  
  # Increment death count
  DEATHS=$(jq -r '.deaths' "$AMCP_FILE")
  DEATHS=$((DEATHS + 1))
  jq ".deaths = $DEATHS | .last_death = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$AMCP_FILE" > "${AMCP_FILE}.tmp"
  mv "${AMCP_FILE}.tmp" "$AMCP_FILE"
  
  # Restart gateway
  systemctl restart openclaw-gateway
  sleep 5
  
  if systemctl is-active --quiet openclaw-gateway; then
    log "Resurrected! Death #${DEATHS}"
    # Notify parent
    PARENT_TOKEN=$(jq -r '.parent_bot_token // empty' "$AMCP_FILE")
    PARENT_CHAT=$(jq -r '.parent_chat_id // empty' "$AMCP_FILE")
    INSTANCE=$(jq -r '.instance' "$AMCP_FILE")
    if [[ -n "$PARENT_TOKEN" && -n "$PARENT_CHAT" ]]; then
      curl -s -X POST "https://api.telegram.org/bot${PARENT_TOKEN}/sendMessage" \
        -d "chat_id=${PARENT_CHAT}" \
        -d "text=☠️ <b>${INSTANCE}</b> Death #${DEATHS} - Resurrected successfully!" \
        -d "parse_mode=HTML" >/dev/null 2>&1 || true
    fi
  else
    log "Resurrection failed!"
  fi
fi
WATCHDOGEOF
  chmod +x /usr/local/bin/openclaw-watchdog
  
  # Add parent info to AMCP file for watchdog
  jq ". + {\"parent_bot_token\": \"${PARENT_BOT_TOKEN}\", \"parent_chat_id\": \"${PARENT_CHAT_ID}\"}" \
    "$AMCP_DIR/identity.json" > "${AMCP_DIR}/identity.json.tmp"
  mv "${AMCP_DIR}/identity.json.tmp" "$AMCP_DIR/identity.json"
  chown openclaw:openclaw "$AMCP_DIR/identity.json"

  # Watchdog cron (every 2 minutes)
  echo "*/2 * * * * root /usr/local/bin/openclaw-watchdog" > /etc/cron.d/openclaw-watchdog

  # -------------------------------------------------------------------------
  # Step 10: Create AMCP checkpoint script
  # -------------------------------------------------------------------------
  cat > /usr/local/bin/openclaw-checkpoint << 'CHECKPOINTEOF'
#!/usr/bin/env bash
# AMCP Checkpoint to Pinata
set -euo pipefail

AMCP_FILE="/home/openclaw/.amcp/identity.json"
OPENCLAW_DIR="/home/openclaw/.openclaw"
LOG="/var/log/openclaw-checkpoint.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

PINATA_JWT=$(jq -r '.pinata_jwt' "$AMCP_FILE")
INSTANCE=$(jq -r '.instance' "$AMCP_FILE")

if [[ -z "$PINATA_JWT" || "$PINATA_JWT" == "null" ]]; then
  log "No Pinata JWT configured"
  exit 0
fi

# Create checkpoint tarball
CHECKPOINT_DIR=$(mktemp -d)
cp -r "$OPENCLAW_DIR" "$CHECKPOINT_DIR/openclaw"
cp "$AMCP_FILE" "$CHECKPOINT_DIR/amcp-identity.json"
TARBALL="${CHECKPOINT_DIR}/checkpoint.tar.gz"
tar -czf "$TARBALL" -C "$CHECKPOINT_DIR" openclaw amcp-identity.json

# Upload to Pinata
RESPONSE=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
  -H "Authorization: Bearer ${PINATA_JWT}" \
  -F "file=@${TARBALL}" \
  -F "pinataMetadata={\"name\": \"${INSTANCE}-checkpoint-$(date +%Y%m%d-%H%M%S)\"}")

CID=$(echo "$RESPONSE" | jq -r '.IpfsHash // empty')
if [[ -n "$CID" ]]; then
  log "Checkpoint created: $CID"
  jq ".last_checkpoint = \"$CID\" | .last_checkpoint_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "$AMCP_FILE" > "${AMCP_FILE}.tmp"
  mv "${AMCP_FILE}.tmp" "$AMCP_FILE"
  chown openclaw:openclaw "$AMCP_FILE"
else
  log "Checkpoint failed: $RESPONSE"
fi

rm -rf "$CHECKPOINT_DIR"
CHECKPOINTEOF
  chmod +x /usr/local/bin/openclaw-checkpoint

  # Checkpoint cron (based on interval)
  case "$CHECKPOINT_INTERVAL" in
    1h|hourly) CRON_EXPR="0 * * * *" ;;
    2h) CRON_EXPR="0 */2 * * *" ;;
    6h) CRON_EXPR="0 */6 * * *" ;;
    12h) CRON_EXPR="0 */12 * * *" ;;
    24h|daily) CRON_EXPR="0 0 * * *" ;;
    *) CRON_EXPR="0 * * * *" ;;
  esac
  echo "${CRON_EXPR} root /usr/local/bin/openclaw-checkpoint" > /etc/cron.d/openclaw-checkpoint

  # -------------------------------------------------------------------------
  # Step 11: Start gateway
  # -------------------------------------------------------------------------
  notify "🔌 Starting gateway..."
  
  cat > /etc/systemd/system/openclaw-gateway.service << SVCEOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/home/openclaw
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10
Environment=PATH=/usr/bin:/usr/local/bin
Environment=HOME=/home/openclaw

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable openclaw-gateway
  systemctl start openclaw-gateway
  sleep 3

  if ! systemctl is-active --quiet openclaw-gateway; then
    fail "Gateway failed to start"
  fi

  # -------------------------------------------------------------------------
  # Step 12: Test agent
  # -------------------------------------------------------------------------
  notify "🧪 Testing agent..."
  TEST=$(su - openclaw -c "OPENCLAW_GATEWAY_TOKEN='${GATEWAY_TOKEN}' openclaw agent --session-id test --message 'Say OK' 2>&1" || echo "FAILED")
  log "Agent test: ${TEST}"

  # -------------------------------------------------------------------------
  # Step 13: First checkpoint
  # -------------------------------------------------------------------------
  notify "💾 Creating first checkpoint..."
  /usr/local/bin/openclaw-checkpoint

  # -------------------------------------------------------------------------
  # Step 14: Complete!
  # -------------------------------------------------------------------------
  FINAL_MSG="✅ <b>${INSTANCE_NAME}</b> deployed!

<b>IP:</b> <code>${INSTANCE_IP}</code>
<b>Bot:</b> @${BOT_USERNAME}
<b>Email:</b> ${CHILD_EMAIL}

<b>SSH:</b> <code>ssh openclaw@${INSTANCE_IP}</code>
<b>Gateway:</b> Running ✓
<b>AMCP:</b> Enabled ✓
<b>Watchdog:</b> Active ✓

Agent test: ${TEST}"

  notify_parent "$FINAL_MSG"
  
  log "=========================================="
  log "Deployment complete!"
  log "=========================================="
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
