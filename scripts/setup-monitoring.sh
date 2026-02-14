#!/usr/bin/env bash
set -euo pipefail

# setup-monitoring.sh - Installs healthcheck monitoring on OpenClaw VM
# Usage: ./setup-monitoring.sh <instance-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <instance-name>"
  exit 1
fi

INSTANCE_NAME="$1"
INSTANCE_DIR="$PROJECT_ROOT/instances/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  echo "ERROR: Instance metadata not found: $METADATA_FILE"
  exit 1
fi

IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY="$HOME/.ssh/openclaw_${INSTANCE_NAME}"

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found: $SSH_KEY"
  exit 1
fi

echo "=== Setting up monitoring for $INSTANCE_NAME ==="
echo "IP: $IP"
echo ""

# Check if monitoring is already set up
echo "→ Checking if monitoring is already configured..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "systemctl --user is-active openclaw-healthcheck.timer" &>/dev/null; then
  echo "✓ Monitoring already configured and active"
  echo ""
  echo "Timer status:"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
    "systemctl --user status openclaw-healthcheck.timer --no-pager" || true
  exit 0
fi

# Create scripts directory
echo "→ Creating scripts directory..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "mkdir -p ~/scripts"

# Create healthcheck script
echo "→ Creating healthcheck script..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" 'cat > ~/scripts/healthcheck.sh' <<'HEALTHCHECK_EOF'
#!/usr/bin/env bash
# OpenClaw Gateway Healthcheck
# Runs every 5 minutes via systemd timer

LOG_FILE="$HOME/logs/healthcheck.log"
mkdir -p "$(dirname "$LOG_FILE")"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "[$(timestamp)] $1" | tee -a "$LOG_FILE"
}

check_gateway() {
  if ! sudo systemctl is-active openclaw-gateway &>/dev/null; then
    log "ERROR: OpenClaw gateway is not running"
    return 1
  fi
  return 0
}

check_port() {
  if ! nc -z 127.0.0.1 18789 2>/dev/null; then
    log "WARNING: Gateway port 18789 not responding"
    return 1
  fi
  return 0
}

check_disk() {
  local usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
  if [ "$usage" -gt 90 ]; then
    log "WARNING: Disk usage high: ${usage}%"
    return 1
  fi
  return 0
}

check_memory() {
  local available=$(free -m | awk 'NR==2 {print $7}')
  if [ "$available" -lt 200 ]; then
    log "WARNING: Low memory: ${available}MB available"
    return 1
  fi
  return 0
}

# Run all checks
CHECKS_PASSED=0
CHECKS_FAILED=0

if check_gateway; then
  ((CHECKS_PASSED++))
else
  ((CHECKS_FAILED++))
fi

if check_port; then
  ((CHECKS_PASSED++))
else
  ((CHECKS_FAILED++))
fi

if check_disk; then
  ((CHECKS_PASSED++))
else
  ((CHECKS_FAILED++))
fi

if check_memory; then
  ((CHECKS_PASSED++))
else
  ((CHECKS_FAILED++))
fi

if [ $CHECKS_FAILED -eq 0 ]; then
  log "✓ All checks passed ($CHECKS_PASSED/4)"
else
  log "⚠ $CHECKS_FAILED checks failed, $CHECKS_PASSED passed"
fi

exit $CHECKS_FAILED
HEALTHCHECK_EOF

# Make healthcheck executable
echo "→ Making healthcheck script executable..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "chmod +x ~/scripts/healthcheck.sh"

# Create systemd service unit
echo "→ Creating systemd service unit..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  'mkdir -p ~/.config/systemd/user'

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  'cat > ~/.config/systemd/user/openclaw-healthcheck.service' <<'SERVICE_EOF'
[Unit]
Description=OpenClaw Gateway Healthcheck
After=openclaw-gateway.service

[Service]
Type=oneshot
ExecStart=%h/scripts/healthcheck.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF

# Create systemd timer unit
echo "→ Creating systemd timer unit..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  'cat > ~/.config/systemd/user/openclaw-healthcheck.timer' <<'TIMER_EOF'
[Unit]
Description=OpenClaw Gateway Healthcheck Timer
Requires=openclaw-healthcheck.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
TIMER_EOF

# Reload systemd and enable timer
echo "→ Enabling and starting healthcheck timer..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "systemctl --user daemon-reload"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "systemctl --user enable openclaw-healthcheck.timer"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "systemctl --user start openclaw-healthcheck.timer"

# Create logrotate config
echo "→ Creating logrotate configuration..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  'mkdir -p ~/logs'

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  'cat > ~/.config/logrotate.conf' <<'LOGROTATE_EOF'
/home/openclaw/logs/healthcheck.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 openclaw openclaw
}
LOGROTATE_EOF

# Run initial healthcheck
echo ""
echo "→ Running initial healthcheck..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "~/scripts/healthcheck.sh"; then
  echo "✓ Initial healthcheck passed"
else
  echo "⚠ Initial healthcheck reported warnings (this is normal during setup)"
fi

# Verify timer is active
echo ""
echo "→ Verifying timer is active..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
  "systemctl --user is-active openclaw-healthcheck.timer" &>/dev/null; then
  echo "✓ Healthcheck timer is active"

  echo ""
  echo "Timer status:"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
    "systemctl --user status openclaw-healthcheck.timer --no-pager" || true

  echo ""
  echo "Next run:"
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" \
    "systemctl --user list-timers openclaw-healthcheck.timer --no-pager" || true
else
  echo "ERROR: Timer is not active"
  exit 1
fi

# Update instance metadata
echo ""
echo "→ Updating instance metadata..."
TMP_METADATA=$(mktemp)
jq '.status = "monitoring-configured"' "$METADATA_FILE" > "$TMP_METADATA"
mv "$TMP_METADATA" "$METADATA_FILE"

echo ""
echo "=== Monitoring setup complete ==="
echo ""
echo "Healthcheck runs every 5 minutes and monitors:"
echo "  • Gateway service status"
echo "  • Port 18789 availability"
echo "  • Disk space usage"
echo "  • Memory availability"
echo ""
echo "View logs: ssh -i $SSH_KEY openclaw@$IP 'tail -f ~/logs/healthcheck.log'"
echo "Timer status: ssh -i $SSH_KEY openclaw@$IP 'systemctl --user status openclaw-healthcheck.timer'"
echo ""
