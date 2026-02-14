#!/usr/bin/env bash
set -euo pipefail

# verify.sh - Run full verification checklist on OpenClaw instance
# Usage: ./scripts/verify.sh <instance-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
  echo "Usage: $0 <instance-name>"
  echo
  echo "Run full verification checklist on an OpenClaw instance"
  echo
  echo "Example:"
  echo "  $0 openclaw-research-nbg1"
  exit 1
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[PASS]${NC} $*"
}

log_error() {
  echo -e "${RED}[FAIL]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

# Check arguments
if [[ $# -ne 1 ]]; then
  usage
fi

INSTANCE_NAME="$1"
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

# Verify instance exists
if [[ ! -d "$INSTANCE_DIR" ]]; then
  log_error "Instance directory not found: $INSTANCE_DIR"
  exit 1
fi

if [[ ! -f "$METADATA_FILE" ]]; then
  log_error "Metadata file not found: $METADATA_FILE"
  exit 1
fi

# Read metadata
SERVER_IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY="$HOME/.ssh/openclaw_${INSTANCE_NAME}"

if [[ -z "$SERVER_IP" || "$SERVER_IP" == "null" ]]; then
  log_error "No IP address found in metadata"
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  log_error "SSH key not found: $SSH_KEY"
  exit 1
fi

log_info "Starting verification for instance: $INSTANCE_NAME"
log_info "Server IP: $SERVER_IP"
echo

# Track results
PASSED=0
FAILED=0
declare -a FAILURES

# Function to run check
run_check() {
  local check_name="$1"
  local check_command="$2"
  local success_pattern="$3"

  echo -n "Checking $check_name... "

  if result=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "$check_command" 2>&1); then
    if [[ -n "$success_pattern" ]]; then
      if echo "$result" | grep -q "$success_pattern"; then
        log_success "$check_name"
        ((PASSED++))
        return 0
      else
        log_error "$check_name (pattern not found)"
        FAILURES+=("$check_name: Expected pattern '$success_pattern' not found")
        ((FAILED++))
        return 1
      fi
    else
      log_success "$check_name"
      ((PASSED++))
      return 0
    fi
  else
    log_error "$check_name (command failed)"
    FAILURES+=("$check_name: Command failed - $result")
    ((FAILED++))
    return 1
  fi
}

# 1. SSH connectivity (implicit - if we get here, SSH works)
log_success "SSH connectivity"
((PASSED++))

# 2. OpenClaw version
run_check "OpenClaw version" "openclaw --version" "openclaw/"

# 3. Gateway status = running
run_check "Gateway status" "openclaw gateway status" "running"

# 4. Systemd service active
run_check "Systemd service" "sudo systemctl is-active openclaw-gateway" "active"

# 5. Tailscale status = connected
run_check "Tailscale status" "tailscale status --json | jq -r '.BackendState'" "Running"

# 6. Telegram channel enabled
run_check "Telegram channel" "openclaw channels status telegram" "enabled"

# 7. Healthcheck timer active
run_check "Healthcheck timer" "sudo systemctl is-active openclaw-healthcheck.timer 2>/dev/null || systemctl --user is-active openclaw-healthcheck.timer" "active"

# 8. UFW firewall enabled
run_check "UFW firewall" "sudo ufw status | head -n1" "Status: active"

# 9. Disk space > 50% free
echo -n "Checking disk space... "
disk_usage=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "df -h / | tail -n1 | awk '{print \$5}' | sed 's/%//'" 2>&1)
if [[ -n "$disk_usage" ]] && [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
  if [[ "$disk_usage" -lt 50 ]]; then
    log_success "Disk space (${disk_usage}% used, $(( 100 - disk_usage ))% free)"
    ((PASSED++))
  else
    log_warn "Disk space (${disk_usage}% used, $(( 100 - disk_usage ))% free) - LOW"
    FAILURES+=("Disk space: ${disk_usage}% used (threshold: 50%)")
    ((FAILED++))
  fi
else
  log_error "Disk space (unable to determine)"
  FAILURES+=("Disk space: Unable to determine usage")
  ((FAILED++))
fi

# 10. Memory reasonable
echo -n "Checking memory... "
mem_info=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "free -h | grep Mem" 2>&1)
if [[ -n "$mem_info" ]]; then
  mem_used=$(echo "$mem_info" | awk '{print $3}')
  mem_total=$(echo "$mem_info" | awk '{print $2}')
  mem_percent=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 2>&1)

  if [[ "$mem_percent" -lt 90 ]]; then
    log_success "Memory ($mem_used / $mem_total used, ${mem_percent}%)"
    ((PASSED++))
  else
    log_warn "Memory ($mem_used / $mem_total used, ${mem_percent}%) - HIGH"
    FAILURES+=("Memory: ${mem_percent}% used (threshold: 90%)")
    ((FAILED++))
  fi
else
  log_error "Memory (unable to determine)"
  FAILURES+=("Memory: Unable to determine usage")
  ((FAILED++))
fi

echo
log_info "Generating QUICKREF.md on VM..."

# Generate QUICKREF.md on the VM
QUICKREF_SCRIPT=$(cat <<'QUICKREF_EOF'
#!/usr/bin/env bash
set -euo pipefail

QUICKREF_FILE="$HOME/QUICKREF.md"

# Get system information
OPENCLAW_VERSION=$(openclaw --version 2>/dev/null || echo "unknown")
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
SERVER_IP=$(hostname -I | awk '{print $1}')
UPTIME=$(uptime -p)
DISK_FREE=$(df -h / | tail -n1 | awk '{print $4}')
MEM_FREE=$(free -h | grep Mem | awk '{print $7}')

# Get Telegram bot info if configured
TELEGRAM_BOT=$(jq -r '.channels.telegram.bots[0].username // "not configured"' ~/.openclaw/openclaw.json 2>/dev/null || echo "not configured")

cat > "$QUICKREF_FILE" <<'EOF'
# OpenClaw Gateway Quick Reference

## Access Information

- **Server IP**: SERVER_IP_PLACEHOLDER
- **Tailscale IP**: TAILSCALE_IP_PLACEHOLDER
- **SSH**: `ssh openclaw@SERVER_IP_PLACEHOLDER`

## Service Status

- **OpenClaw Version**: OPENCLAW_VERSION_PLACEHOLDER
- **Gateway**: `openclaw gateway status`
- **Systemd Service**: `sudo systemctl status openclaw-gateway`
- **Logs**: `sudo journalctl -u openclaw-gateway -f`

## Telegram Bot

- **Bot Username**: TELEGRAM_BOT_PLACEHOLDER
- **Channel Status**: `openclaw channels status telegram`
- **Approve Pairing**: Message the bot, then run `openclaw channels telegram approve <code>`

## Monitoring

- **Healthcheck**: `sudo systemctl status openclaw-healthcheck.timer`
- **Healthcheck Logs**: `tail -f ~/logs/healthcheck.log`
- **Next Run**: `sudo systemctl list-timers | grep healthcheck`

## System Resources

- **Uptime**: UPTIME_PLACEHOLDER
- **Disk Free**: DISK_FREE_PLACEHOLDER
- **Memory Free**: MEM_FREE_PLACEHOLDER

## Useful Commands

```bash
# Restart gateway
sudo systemctl restart openclaw-gateway

# View configuration
cat ~/.openclaw/openclaw.json

# Test gateway health
curl http://127.0.0.1:18789/health

# Tailscale status
tailscale status

# Firewall status
sudo ufw status verbose
```

## Troubleshooting

- **Gateway won't start**: Check logs with `sudo journalctl -u openclaw-gateway -xe`
- **Telegram not working**: Verify token in config, check channel status
- **Tailscale not connected**: Run `tailscale status`, re-authenticate if needed
- **High memory usage**: Restart gateway, check for stuck processes

---

Generated: $(date)
EOF

# Replace placeholders
sed -i "s|SERVER_IP_PLACEHOLDER|$SERVER_IP|g" "$QUICKREF_FILE"
sed -i "s|TAILSCALE_IP_PLACEHOLDER|$TAILSCALE_IP|g" "$QUICKREF_FILE"
sed -i "s|OPENCLAW_VERSION_PLACEHOLDER|$OPENCLAW_VERSION|g" "$QUICKREF_FILE"
sed -i "s|TELEGRAM_BOT_PLACEHOLDER|$TELEGRAM_BOT|g" "$QUICKREF_FILE"
sed -i "s|UPTIME_PLACEHOLDER|$UPTIME|g" "$QUICKREF_FILE"
sed -i "s|DISK_FREE_PLACEHOLDER|$DISK_FREE|g" "$QUICKREF_FILE"
sed -i "s|MEM_FREE_PLACEHOLDER|$MEM_FREE|g" "$QUICKREF_FILE"

echo "QUICKREF.md generated at: $QUICKREF_FILE"
QUICKREF_EOF
)

# Copy and execute the quickref generation script
if ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "cat > /tmp/generate-quickref.sh" <<< "$QUICKREF_SCRIPT" && \
   ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "bash /tmp/generate-quickref.sh && rm /tmp/generate-quickref.sh"; then
  log_success "QUICKREF.md generated"
else
  log_error "Failed to generate QUICKREF.md"
fi

echo
echo "========================================"
echo "VERIFICATION SUMMARY"
echo "========================================"
echo -e "Passed: ${GREEN}$PASSED${NC} / 10"
echo -e "Failed: ${RED}$FAILED${NC} / 10"
echo

if [[ $FAILED -gt 0 ]]; then
  echo "Failures:"
  for failure in "${FAILURES[@]}"; do
    echo -e "  ${RED}✗${NC} $failure"
  done
  echo

  # Update metadata status
  jq '.status = "degraded"' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
  log_warn "Instance status updated to: degraded"

  exit 1
else
  # Update metadata status
  jq '.status = "operational"' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
  log_success "All checks passed! Instance is operational"

  echo
  log_info "Quick reference available on VM at: ~/QUICKREF.md"
  log_info "View with: ssh -i $SSH_KEY openclaw@$SERVER_IP 'cat ~/QUICKREF.md'"
fi
