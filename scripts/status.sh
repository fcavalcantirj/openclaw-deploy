#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Function to print colored output
print_status() {
  local color=$1
  local message=$2
  echo -e "${color}${message}${NC}"
}

# Function to show usage
usage() {
  cat << EOF
Usage: $0 <instance-name>

Show detailed status of an OpenClaw instance.

Arguments:
  instance-name    Name of the instance to check

Example:
  $0 mybot
EOF
  exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
  usage
fi

INSTANCE_NAME=$1
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

# Check if instance exists
if [ ! -f "$METADATA_FILE" ]; then
  print_status "$RED" "✗ Instance '$INSTANCE_NAME' not found"
  echo ""
  echo "Available instances:"
  if [ -d "$INSTANCES_DIR" ] && [ "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]; then
    for dir in "$INSTANCES_DIR"/*; do
      if [ -d "$dir" ] && [ -f "$dir/metadata.json" ]; then
        echo "  - $(basename "$dir")"
      fi
    done
  else
    echo "  (none)"
  fi
  exit 1
fi

# Load metadata
SERVER_IP=$(jq -r '.ip // "unknown"' "$METADATA_FILE")
TAILSCALE_IP=$(jq -r '.tailscale_ip // "unknown"' "$METADATA_FILE")
REGION=$(jq -r '.region // "unknown"' "$METADATA_FILE")
STATUS=$(jq -r '.status // "unknown"' "$METADATA_FILE")
CREATED_AT=$(jq -r '.created_at // "unknown"' "$METADATA_FILE")
OPENCLAW_VERSION=$(jq -r '.openclaw_version // "unknown"' "$METADATA_FILE")
TELEGRAM_BOT=$(jq -r '.telegram_bot // "not configured"' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key_path // .ssh_key // ""' "$METADATA_FILE")

# Display basic info
print_status "$BLUE" "═══════════════════════════════════════════════════"
print_status "$BLUE" "  OpenClaw Instance Status: $INSTANCE_NAME"
print_status "$BLUE" "═══════════════════════════════════════════════════"
echo ""
echo "Basic Information:"
echo "  Name:            $INSTANCE_NAME"
echo "  Region:          $REGION"
echo "  Status:          $STATUS"
echo "  Created:         $CREATED_AT"
echo "  Server IP:       $SERVER_IP"
echo "  Tailscale IP:    $TAILSCALE_IP"
echo "  OpenClaw:        $OPENCLAW_VERSION"
echo "  Telegram Bot:    $TELEGRAM_BOT"
echo ""

# Check if VM is reachable
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
  print_status "$YELLOW" "⚠ SSH key not found - cannot perform live checks"
  exit 0
fi

print_status "$BLUE" "Performing live checks..."
echo ""

# SSH connection test
echo -n "  SSH Connectivity:     "
if timeout 5 ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "openclaw@$SERVER_IP" "exit" 2>/dev/null; then
  print_status "$GREEN" "✓ Connected"
  SSH_OK=true
else
  print_status "$RED" "✗ Unreachable"
  SSH_OK=false
fi

if [ "$SSH_OK" = false ]; then
  echo ""
  print_status "$YELLOW" "⚠ Cannot reach VM - no further live checks possible"
  echo ""
  echo "Troubleshooting:"
  echo "  • Check if VM is running: hcloud server list"
  echo "  • Verify firewall allows SSH from your IP"
  echo "  • Try connecting manually: ssh -i $SSH_KEY openclaw@$SERVER_IP"
  exit 0
fi

# OpenClaw version
echo -n "  OpenClaw Version:     "
LIVE_VERSION=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "openclaw --version 2>/dev/null || echo 'not installed'" 2>/dev/null)
if [ "$LIVE_VERSION" != "not installed" ]; then
  print_status "$GREEN" "✓ $LIVE_VERSION"
else
  print_status "$RED" "✗ Not installed"
fi

# Gateway status
echo -n "  Gateway Status:       "
GATEWAY_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "openclaw gateway status 2>/dev/null | grep -oP 'Status: \K\w+' || echo 'unknown'" 2>/dev/null)
if [ "$GATEWAY_STATUS" = "running" ]; then
  print_status "$GREEN" "✓ Running"
elif [ "$GATEWAY_STATUS" = "stopped" ]; then
  print_status "$YELLOW" "⚠ Stopped"
else
  print_status "$RED" "✗ Unknown"
fi

# Systemd service
echo -n "  Systemd Service:      "
SYSTEMD_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "systemctl --user is-active openclaw-gateway 2>/dev/null || echo 'inactive'" 2>/dev/null)
if [ "$SYSTEMD_STATUS" = "active" ]; then
  print_status "$GREEN" "✓ Active"
else
  print_status "$RED" "✗ $SYSTEMD_STATUS"
fi

# Tailscale status
echo -n "  Tailscale:            "
TAILSCALE_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "sudo tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo 'not installed'" 2>/dev/null)
if [ "$TAILSCALE_STATUS" = "Running" ]; then
  print_status "$GREEN" "✓ Connected"
elif [ "$TAILSCALE_STATUS" = "not installed" ]; then
  print_status "$YELLOW" "⚠ Not installed"
else
  print_status "$YELLOW" "⚠ $TAILSCALE_STATUS"
fi

# Healthcheck timer
echo -n "  Healthcheck Timer:    "
TIMER_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "systemctl --user is-active openclaw-healthcheck.timer 2>/dev/null || echo 'inactive'" 2>/dev/null)
if [ "$TIMER_STATUS" = "active" ]; then
  print_status "$GREEN" "✓ Active"
else
  print_status "$YELLOW" "⚠ $TIMER_STATUS"
fi

# UFW firewall
echo -n "  UFW Firewall:         "
UFW_STATUS=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "sudo ufw status 2>/dev/null | head -n1 | grep -o 'active' || echo 'inactive'" 2>/dev/null)
if [ "$UFW_STATUS" = "active" ]; then
  print_status "$GREEN" "✓ Active"
else
  print_status "$YELLOW" "⚠ Inactive"
fi

# Disk space
echo -n "  Disk Space:           "
DISK_USAGE=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "df -h / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null)
DISK_FREE=$((100 - DISK_USAGE))
if [ "$DISK_FREE" -gt 50 ]; then
  print_status "$GREEN" "✓ ${DISK_FREE}% free"
elif [ "$DISK_FREE" -gt 20 ]; then
  print_status "$YELLOW" "⚠ ${DISK_FREE}% free"
else
  print_status "$RED" "✗ ${DISK_FREE}% free (low)"
fi

# Memory usage
echo -n "  Memory Usage:         "
MEM_USAGE=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 2>/dev/null)
if [ "$MEM_USAGE" -lt 90 ]; then
  print_status "$GREEN" "✓ ${MEM_USAGE}%"
else
  print_status "$RED" "✗ ${MEM_USAGE}% (high)"
fi

# Recent logs
echo ""
echo "Recent Gateway Logs:"
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$SERVER_IP" "journalctl --user -u openclaw-gateway -n 5 --no-pager 2>/dev/null || echo '  (no logs available)'" 2>/dev/null | sed 's/^/  /'

echo ""
print_status "$BLUE" "═══════════════════════════════════════════════════"
echo ""
echo "Quick Actions:"
echo "  SSH to instance:     ssh -i $SSH_KEY openclaw@$SERVER_IP"
echo "  View full logs:      ssh -i $SSH_KEY openclaw@$SERVER_IP 'journalctl --user -u openclaw-gateway -f'"
echo "  Restart gateway:     ssh -i $SSH_KEY openclaw@$SERVER_IP 'openclaw gateway restart'"
echo "  View QUICKREF:       ssh -i $SSH_KEY openclaw@$SERVER_IP 'cat ~/QUICKREF.md'"
echo ""
