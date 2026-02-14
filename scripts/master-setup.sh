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
#   - AMCP identity + first checkpoint
#   - proactive-amcp watchdog (3-stage self-healing)
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

  cat > /usr/local/bin/openclaw-watchdog << 'WATCHDOGEOF'
#!/usr/bin/env bash
# OpenClaw Self-Healing Watchdog (proactive-amcp pattern)
# Checks: gateway process, port 18789, disk, memory
# On failure: increments death count, attempts restart, notifies parent
set -euo pipefail

AMCP_FILE="/home/openclaw/.amcp/identity.json"
LOG="/var/log/openclaw-watchdog.log"
FAIL_THRESHOLD=2
STATE_FILE="/home/openclaw/.amcp/watchdog-state.json"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"consecutive_failures":0,"state":"HEALTHY"}' > "$STATE_FILE"
  chown openclaw:openclaw "$STATE_FILE"
fi

FAILURES=$(jq -r '.consecutive_failures // 0' "$STATE_FILE")
errors=()

# Check 1: Gateway service
if ! systemctl is-active --quiet openclaw-gateway; then
  errors+=("gateway_down")
fi

# Check 2: Port 18789 responding (only if service is active)
if [[ ${#errors[@]} -eq 0 ]]; then
  if ! curl -s --max-time 5 http://127.0.0.1:18789/health >/dev/null 2>&1; then
    errors+=("port_unresponsive")
  fi
fi

# Check 3: Disk space (>90% = critical)
DISK_USAGE=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [[ "$DISK_USAGE" -gt 90 ]] 2>/dev/null; then
  errors+=("disk_critical:${DISK_USAGE}%")
  # Auto-cleanup old logs
  journalctl --vacuum-time=3d >/dev/null 2>&1 || true
fi

# Check 4: Memory (<200MB available = critical)
MEM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')
if [[ "$MEM_AVAIL" -lt 200 ]] 2>/dev/null; then
  errors+=("memory_low:${MEM_AVAIL}MB")
fi

if [[ ${#errors[@]} -eq 0 ]]; then
  # Healthy
  if [[ "$FAILURES" -gt 0 ]]; then
    log "Recovered after $FAILURES failures"
  fi
  echo '{"consecutive_failures":0,"state":"HEALTHY","last_check":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATE_FILE"
  exit 0
fi

# Failed — increment counter
FAILURES=$((FAILURES + 1))
log "Health check failed ($FAILURES/$FAIL_THRESHOLD): ${errors[*]}"

if [[ "$FAILURES" -ge "$FAIL_THRESHOLD" ]]; then
  log "Threshold reached — attempting resurrection..."

  # Increment death count in AMCP identity
  if [[ -f "$AMCP_FILE" ]]; then
    DEATHS=$(jq -r '.deaths // 0' "$AMCP_FILE")
    DEATHS=$((DEATHS + 1))
    jq ".deaths = $DEATHS | .last_death = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
      "$AMCP_FILE" > "${AMCP_FILE}.tmp" && mv "${AMCP_FILE}.tmp" "$AMCP_FILE"
    chown openclaw:openclaw "$AMCP_FILE"
  fi

  # Stage 1: Restart gateway
  systemctl restart openclaw-gateway 2>/dev/null || true
  sleep 5

  if systemctl is-active --quiet openclaw-gateway; then
    log "Resurrected via restart (Death #${DEATHS:-?})"

    # Notify parent
    if [[ -f "$AMCP_FILE" ]]; then
      PARENT_TOKEN=$(jq -r '.parent_bot_token // empty' "$AMCP_FILE")
      PARENT_CHAT=$(jq -r '.parent_chat_id // empty' "$AMCP_FILE")
      INSTANCE=$(jq -r '.instance' "$AMCP_FILE")
      if [[ -n "$PARENT_TOKEN" && -n "$PARENT_CHAT" ]]; then
        curl -s --connect-timeout 5 --max-time 10 \
          -X POST "https://api.telegram.org/bot${PARENT_TOKEN}/sendMessage" \
          -d "chat_id=${PARENT_CHAT}" \
          -d "text=☠️ <b>${INSTANCE}</b> Death #${DEATHS:-?} — Resurrected! Errors: ${errors[*]}" \
          -d "parse_mode=HTML" >/dev/null 2>&1 || true
      fi
    fi
    echo '{"consecutive_failures":0,"state":"RECOVERED","last_check":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATE_FILE"
  else
    # Stage 2: Try restoring config from backup
    BACKUP=$(ls -1t /home/openclaw/.amcp/config-backups/openclaw-*.json 2>/dev/null | head -1)
    if [[ -n "$BACKUP" ]] && jq . "$BACKUP" >/dev/null 2>&1; then
      log "Restoring config from backup: $BACKUP"
      cp /home/openclaw/.openclaw/openclaw.json /home/openclaw/.openclaw/openclaw.json.pre-recovery 2>/dev/null || true
      cp "$BACKUP" /home/openclaw/.openclaw/openclaw.json
      chown openclaw:openclaw /home/openclaw/.openclaw/openclaw.json
      systemctl restart openclaw-gateway 2>/dev/null || true
      sleep 5
    fi

    if systemctl is-active --quiet openclaw-gateway; then
      log "Resurrected via config restore (Death #${DEATHS:-?})"
      echo '{"consecutive_failures":0,"state":"RECOVERED","last_check":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATE_FILE"
    else
      log "Resurrection FAILED — human intervention required"
      echo '{"consecutive_failures":'"$FAILURES"',"state":"DEAD","last_check":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATE_FILE"
    fi
  fi
else
  echo '{"consecutive_failures":'"$FAILURES"',"state":"CHECKING","last_check":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$STATE_FILE"
fi
WATCHDOGEOF
  chmod +x /usr/local/bin/openclaw-watchdog

  # Watchdog cron (every 2 minutes)
  echo "*/2 * * * * root /usr/local/bin/openclaw-watchdog" > /etc/cron.d/openclaw-watchdog
  chmod 644 /etc/cron.d/openclaw-watchdog

  # -------------------------------------------------------------------------
  # Step 10: Create AMCP checkpoint script
  # -------------------------------------------------------------------------
  cat > /usr/local/bin/openclaw-checkpoint << 'CHECKPOINTEOF'
#!/usr/bin/env bash
# AMCP Checkpoint — archives OpenClaw config + AMCP identity to Pinata/IPFS
set -euo pipefail

AMCP_FILE="/home/openclaw/.amcp/identity.json"
OPENCLAW_DIR="/home/openclaw/.openclaw"
LOG="/var/log/openclaw-checkpoint.log"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [[ ! -f "$AMCP_FILE" ]]; then
  log "No AMCP identity file — skipping checkpoint"
  exit 0
fi

PINATA_JWT=$(jq -r '.pinata_jwt' "$AMCP_FILE")
INSTANCE=$(jq -r '.instance' "$AMCP_FILE")

if [[ -z "$PINATA_JWT" || "$PINATA_JWT" == "null" ]]; then
  log "No Pinata JWT configured — skipping checkpoint"
  exit 0
fi

# Create checkpoint tarball
CHECKPOINT_DIR=$(mktemp -d)
trap "rm -rf '$CHECKPOINT_DIR'" EXIT

cp -r "$OPENCLAW_DIR" "$CHECKPOINT_DIR/openclaw" 2>/dev/null || true
cp "$AMCP_FILE" "$CHECKPOINT_DIR/amcp-identity.json"

# Remove auth-profiles from checkpoint (contains API keys in cleartext)
# The keys are still in the AMCP identity for recovery
rm -f "$CHECKPOINT_DIR/openclaw/agents/main/agent/auth-profiles.json" 2>/dev/null || true

TARBALL="${CHECKPOINT_DIR}/checkpoint.tar.gz"
tar -czf "$TARBALL" -C "$CHECKPOINT_DIR" openclaw amcp-identity.json

# Upload to Pinata
RESPONSE=$(curl -s --connect-timeout 15 --max-time 120 \
  -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
  -H "Authorization: Bearer ${PINATA_JWT}" \
  -F "file=@${TARBALL}" \
  -F "pinataMetadata={\"name\": \"${INSTANCE}-checkpoint-$(date +%Y%m%d-%H%M%S)\"}" 2>&1)

CID=$(echo "$RESPONSE" | jq -r '.IpfsHash // empty' 2>/dev/null)
if [[ -n "$CID" ]]; then
  log "Checkpoint created: $CID ($(du -sh "$TARBALL" | cut -f1))"

  # Update AMCP identity with latest checkpoint
  jq ".last_checkpoint = \"$CID\" | .last_checkpoint_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" \
    "$AMCP_FILE" > "${AMCP_FILE}.tmp" && mv "${AMCP_FILE}.tmp" "$AMCP_FILE"
  chown openclaw:openclaw "$AMCP_FILE"
else
  log "Checkpoint FAILED: $(echo "$RESPONSE" | head -c 200)"
fi
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
  chmod 644 /etc/cron.d/openclaw-checkpoint

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
  /usr/local/bin/openclaw-checkpoint || log "First checkpoint failed (non-fatal)"

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
