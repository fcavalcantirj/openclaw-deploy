#!/usr/bin/env bash
# =============================================================================
# master-setup.sh — Child OpenClaw with full identity stack
# =============================================================================
# Runs on the target VM (uploaded by deploy.sh with credentials templated in).
# Creates:
#   - OpenClaw installation + gateway config
#   - Telegram bot config
#   - AgentMail inbox
#   - AgentMemory vault
#   - AMCP identity + proactive-amcp (watchdog, checkpoints, secrets)
# =============================================================================
set -euo pipefail

# Credentials (replaced by deploy.sh via sed)
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
CHILD_SOLVR_API_KEY="__CHILD_SOLVR_API_KEY__"
PARENT_SOLVR_NAME="__PARENT_SOLVR_NAME__"

LOG_FILE="/var/log/openclaw-setup.log"
CHILD_EMAIL="${INSTANCE_NAME}@agentmail.to"
SETUP_START=$(date +%s)

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

  notify "Starting deployment..."

  # -------------------------------------------------------------------------
  # Step 1: System setup
  # -------------------------------------------------------------------------
  notify "Updating system..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || fail "apt-get update failed"
  apt-get upgrade -y -qq
  apt-get install -y -qq curl git jq python3 python3-pip || fail "Failed to install base packages"

  # -------------------------------------------------------------------------
  # Step 2: Node.js
  # -------------------------------------------------------------------------
  notify "Installing Node.js..."
  if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 22 ]]; then
    curl -fsSL --connect-timeout 15 --max-time 60 https://deb.nodesource.com/setup_22.x | bash - || fail "NodeSource setup failed"
    apt-get install -y -qq nodejs || fail "Node.js install failed"
  fi
  log "Node: $(node -v), npm: $(npm -v)"

  # -------------------------------------------------------------------------
  # Step 2b: Install amcp-protocol CLI
  # -------------------------------------------------------------------------
  notify "Installing amcp-protocol CLI..."
  if ! command -v amcp &>/dev/null; then
    npm install -g @amcp/cli || fail "amcp-protocol CLI install failed"
  fi
  log "AMCP CLI: $(amcp --version 2>/dev/null || echo 'installed')"

  # -------------------------------------------------------------------------
  # Step 2b2: Install Claude Code CLI
  # -------------------------------------------------------------------------
  notify "Installing Claude Code CLI..."
  if ! command -v claude &>/dev/null; then
    npm install -g @anthropic-ai/claude-code || fail "Claude Code CLI install failed"
  fi
  log "Claude Code: $(claude --version 2>/dev/null || echo 'installed')"

  # -------------------------------------------------------------------------
  # Step 2c: Install proactive-amcp
  # -------------------------------------------------------------------------
  notify "Installing proactive-amcp..."
  if ! command -v proactive-amcp &>/dev/null; then
    # Primary: install via clawhub
    if command -v clawhub &>/dev/null && clawhub install proactive-amcp 2>/dev/null; then
      log "proactive-amcp installed via clawhub"
    else
      # Fallback: install via npm
      npm install -g proactive-amcp || fail "proactive-amcp install failed"
      log "proactive-amcp installed via npm"
    fi
  fi
  proactive-amcp --help >/dev/null 2>&1 || log "Warning: proactive-amcp --help returned non-zero (may be expected)"
  log "proactive-amcp: $(proactive-amcp --version 2>/dev/null || echo 'installed')"

  # -------------------------------------------------------------------------
  # Step 3: Create openclaw user
  # -------------------------------------------------------------------------
  notify "Creating user..."
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
  notify "Installing OpenClaw..."
  if ! command -v openclaw &>/dev/null; then
    npm install -g openclaw || fail "OpenClaw install failed"
  fi
  log "OpenClaw: $(openclaw --version 2>/dev/null || echo 'installed')"

  # -------------------------------------------------------------------------
  # Step 5: Create AgentMail inbox
  # -------------------------------------------------------------------------
  notify "Creating email inbox..."
  if [[ -n "$AGENTMAIL_API_KEY" ]]; then
    INBOX_RESULT=$(curl -s --connect-timeout 10 --max-time 30 \
      -X POST "https://api.agentmail.to/v1/inboxes" \
      -H "Authorization: Bearer ${AGENTMAIL_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"username\": \"${INSTANCE_NAME}\"}" 2>&1 || echo '{}')
    log "AgentMail: ${CHILD_EMAIL} (response: $(echo "$INBOX_RESULT" | jq -r '.id // .error // "ok"' 2>/dev/null))"
  else
    log "AgentMail: skipped (no API key)"
  fi

  # -------------------------------------------------------------------------
  # Step 6: Create AgentMemory vault
  # -------------------------------------------------------------------------
  notify "Creating memory vault..."
  if [[ -n "$AGENTMEMORY_API_KEY" ]]; then
    log "AgentMemory: ${INSTANCE_NAME} vault configured (created on first use)"
  else
    log "AgentMemory: skipped (no API key)"
  fi

  # -------------------------------------------------------------------------
  # Step 7: Initialize AMCP identity (via amcp CLI — real KERI identity)
  # -------------------------------------------------------------------------
  notify "Initializing AMCP..."
  AMCP_DIR="/home/openclaw/.amcp"
  mkdir -p "$AMCP_DIR/checkpoints" "$AMCP_DIR/config-backups"

  AMCP_IDENTITY="$AMCP_DIR/identity.json"

  # Create real KERI identity via amcp CLI (idempotent — skip if valid identity exists)
  if [[ -f "$AMCP_IDENTITY" ]] && amcp identity validate --file "$AMCP_IDENTITY" >/dev/null 2>&1; then
    log "AMCP identity already exists and is valid — skipping creation"
  else
    amcp identity create --seed "${AMCP_SEED}" --instance "${INSTANCE_NAME}" --out "$AMCP_IDENTITY" \
      || fail "amcp identity create failed"
  fi

  # Validate the identity is proper KERI
  if ! amcp identity validate --file "$AMCP_IDENTITY"; then
    fail "AMCP identity validation failed — identity.json is not valid KERI"
  fi

  chown -R openclaw:openclaw "$AMCP_DIR"
  AMCP_AID=$(amcp identity validate --file "$AMCP_IDENTITY" --json 2>/dev/null | jq -r '.aid // empty')
  log "AMCP AID: ${AMCP_AID:0:20}..."

  # Store secrets in proactive-amcp config (NOT in identity.json)
  proactive-amcp config set pinata_jwt "$PINATA_JWT" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set pinata_jwt"
  proactive-amcp config set parent_bot_token "$PARENT_BOT_TOKEN" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set parent_bot_token"
  proactive-amcp config set parent_chat_id "$PARENT_CHAT_ID" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set parent_chat_id"
  proactive-amcp config set instance_name "$INSTANCE_NAME" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set instance_name"

  # Store Anthropic API key (needed for proactive-amcp diagnose)
  proactive-amcp config set anthropic.apiKey "$ANTHROPIC_API_KEY" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set anthropic.apiKey"

  # Store Solvr credentials (if child was registered)
  if [[ -n "$CHILD_SOLVR_API_KEY" ]]; then
    proactive-amcp config set solvr_api_key "$CHILD_SOLVR_API_KEY" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set solvr_api_key"
    proactive-amcp config set parent_solvr_name "$PARENT_SOLVR_NAME" --amcp-dir "$AMCP_DIR" || log "Warning: failed to set parent_solvr_name"
    log "Solvr credentials stored in proactive-amcp config"
  fi

  chown -R openclaw:openclaw "$AMCP_DIR"
  log "Secrets stored in proactive-amcp config (not identity.json)"

  # -------------------------------------------------------------------------
  # Step 8: Configure OpenClaw
  # -------------------------------------------------------------------------
  notify "Configuring OpenClaw..."

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
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      },
      "proactive-amcp": {
        "enabled": true,
        "config": {
          "parentSolvrName": "${PARENT_SOLVR_NAME}"
        }
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/openclaw/.openclaw/workspace",
      "heartbeat": {
        "every": "2h"
      }
    }
  },
  "logging": {
    "redactSensitive": true,
    "level": "info"
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

  # Backup config for recovery
  cp /home/openclaw/.openclaw/openclaw.json "$AMCP_DIR/config-backups/openclaw-initial.json"
  chown openclaw:openclaw "$AMCP_DIR/config-backups/openclaw-initial.json"

  # -------------------------------------------------------------------------
  # Step 9: Install proactive-amcp watchdog
  # -------------------------------------------------------------------------
  notify "Setting up watchdog..."

  # Delegate to proactive-amcp: installs watchdog script, systemd/cron, and self-healing logic
  proactive-amcp install --watchdog-interval 120 \
    --service openclaw-gateway \
    --port 18789 \
    --amcp-dir "$AMCP_DIR" \
    --notify-token "$PARENT_BOT_TOKEN" \
    --notify-chat "$PARENT_CHAT_ID" \
    || fail "proactive-amcp watchdog install failed"

  # Verify watchdog is active
  if systemctl is-active --quiet proactive-amcp-watchdog.timer 2>/dev/null || [[ -f /etc/cron.d/proactive-amcp-watchdog ]]; then
    log "Watchdog installed (interval: 120s)"
  else
    log "Warning: watchdog installed but timer/cron not detected — proactive-amcp may use different scheduling"
  fi

  # -------------------------------------------------------------------------
  # Step 10: Install proactive-amcp checkpoint
  # -------------------------------------------------------------------------
  notify "Setting up checkpoints..."

  # Convert human-readable interval to cron expression
  case "$CHECKPOINT_INTERVAL" in
    1h|hourly) CHECKPOINT_CRON="0 * * * *" ;;
    2h)        CHECKPOINT_CRON="0 */2 * * *" ;;
    6h)        CHECKPOINT_CRON="0 */6 * * *" ;;
    12h)       CHECKPOINT_CRON="0 */12 * * *" ;;
    24h|daily) CHECKPOINT_CRON="0 0 * * *" ;;
    *)         CHECKPOINT_CRON="0 */6 * * *" ;;
  esac

  # Delegate to proactive-amcp: installs checkpoint script, cron, and IPFS upload logic
  proactive-amcp install --checkpoint-schedule "$CHECKPOINT_CRON" \
    --amcp-dir "$AMCP_DIR" \
    --openclaw-dir "/home/openclaw/.openclaw" \
    || fail "proactive-amcp checkpoint install failed"

  log "Checkpoint installed (schedule: $CHECKPOINT_CRON)"

  # -------------------------------------------------------------------------
  # Step 11: Start gateway
  # -------------------------------------------------------------------------
  notify "Starting gateway..."

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
  sleep 5

  if ! systemctl is-active --quiet openclaw-gateway; then
    # Check journal for the actual error
    log "Gateway startup logs:"
    journalctl -u openclaw-gateway --no-pager -n 20 2>&1 | tee -a "$LOG_FILE" || true
    fail "Gateway failed to start — check logs above"
  fi
  log "Gateway is running"

  # -------------------------------------------------------------------------
  # Step 12: Test agent
  # -------------------------------------------------------------------------
  notify "Testing agent..."
  TEST=$(su - openclaw -c "OPENCLAW_GATEWAY_TOKEN='${GATEWAY_TOKEN}' openclaw agent --session-id test --message 'Say OK' 2>&1" || echo "FAILED")
  log "Agent test: ${TEST:0:200}"

  # -------------------------------------------------------------------------
  # Step 13: First checkpoint
  # -------------------------------------------------------------------------
  notify "Creating first checkpoint..."
  proactive-amcp checkpoint --amcp-dir "$AMCP_DIR" || log "First checkpoint failed (non-fatal)"

  # -------------------------------------------------------------------------
  # Step 14: Complete!
  # -------------------------------------------------------------------------
  ELAPSED=$(( $(date +%s) - SETUP_START ))
  FINAL_MSG="✅ <b>${INSTANCE_NAME}</b> deployed! (${ELAPSED}s)

<b>IP:</b> <code>${INSTANCE_IP}</code>
<b>Bot:</b> @${BOT_USERNAME}
<b>Email:</b> ${CHILD_EMAIL}

<b>Gateway:</b> Running
<b>AMCP:</b> Enabled (checkpoints every ${CHECKPOINT_INTERVAL})
<b>Watchdog:</b> Active (2-stage self-healing)

<b>SSH:</b> <code>ssh openclaw@${INSTANCE_IP}</code>"

  notify_parent "$FINAL_MSG"

  log "=========================================="
  log "Deployment complete! (${ELAPSED}s)"
  log "=========================================="
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
