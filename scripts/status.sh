#!/bin/bash
set -euo pipefail

# status.sh - Show detailed status of an OpenClaw instance
# Usage: ./scripts/status.sh <instance-name>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

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

load_instance "$INSTANCE_NAME" || exit 1

METADATA_FILE="$INSTANCES_DIR/$INSTANCE_NAME/metadata.json"
TAILSCALE_IP=$(jq -r '.tailscale_ip // "unknown"' "$METADATA_FILE")
REGION="$INSTANCE_REGION"
STATUS="$INSTANCE_STATUS"
CREATED_AT=$(jq -r '.created_at // "unknown"' "$METADATA_FILE")
OPENCLAW_VERSION=$(jq -r '.openclaw_version // "unknown"' "$METADATA_FILE")
TELEGRAM_BOT=$(jq -r '.telegram_bot // "not configured"' "$METADATA_FILE")

# Display basic info
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OpenClaw Instance Status: $INSTANCE_NAME${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Basic Information:"
echo "  Name:            $INSTANCE_NAME"
echo "  Region:          $REGION"
echo "  Status:          $STATUS"
echo "  Created:         $CREATED_AT"
echo "  Server IP:       $INSTANCE_IP"
echo "  SSH User:        $INSTANCE_SSH_USER"
echo "  Tailscale IP:    $TAILSCALE_IP"
echo "  OpenClaw:        $OPENCLAW_VERSION"
echo "  Telegram Bot:    $TELEGRAM_BOT"
echo ""

# Check if VM is reachable
if [[ -z "$INSTANCE_SSH_KEY" || ! -f "$INSTANCE_SSH_KEY" ]]; then
  log_warn "SSH key not found - cannot perform live checks"
  exit 0
fi

log_info "Performing live checks..."
echo ""

# SSH connection test
echo -n "  SSH Connectivity:     "
if ssh_check "$INSTANCE_NAME" 5 2>/dev/null; then
  log_success "Connected"
  SSH_OK=true
else
  log_error "Unreachable"
  SSH_OK=false
fi

if [ "$SSH_OK" = false ]; then
  echo ""
  log_warn "Cannot reach VM - no further live checks possible"
  echo ""
  echo "Troubleshooting:"
  echo "  - Check if VM is running: hcloud server list"
  echo "  - Verify firewall allows SSH from your IP"
  echo "  - Try connecting manually: claw ssh $INSTANCE_NAME"
  exit 0
fi

# OpenClaw version
echo -n "  OpenClaw Version:     "
LIVE_VERSION=$(ssh_exec "$INSTANCE_NAME" "openclaw --version 2>/dev/null || echo 'not installed'" 2>/dev/null)
if [ "$LIVE_VERSION" != "not installed" ]; then
  log_success "$LIVE_VERSION"
else
  log_error "Not installed"
fi

# Gateway status
echo -n "  Gateway Status:       "
GATEWAY_STATUS=$(ssh_exec "$INSTANCE_NAME" "openclaw gateway status 2>/dev/null | grep -oP 'Status: \K\w+' || echo 'unknown'" 2>/dev/null)
if [ "$GATEWAY_STATUS" = "running" ]; then
  log_success "Running"
elif [ "$GATEWAY_STATUS" = "stopped" ]; then
  log_warn "Stopped"
else
  log_error "Unknown"
fi

# Systemd service
echo -n "  Systemd Service:      "
SYSTEMD_STATUS=$(ssh_exec "$INSTANCE_NAME" "systemctl is-active openclaw-gateway 2>/dev/null || echo 'inactive'" 2>/dev/null)
if [ "$SYSTEMD_STATUS" = "active" ]; then
  log_success "Active"
else
  log_error "$SYSTEMD_STATUS"
fi

# Tailscale status
echo -n "  Tailscale:            "
TAILSCALE_STATUS=$(ssh_exec "$INSTANCE_NAME" "tailscale status --json 2>/dev/null | jq -r '.BackendState' || echo 'not installed'" 2>/dev/null)
if [ "$TAILSCALE_STATUS" = "Running" ]; then
  log_success "Connected"
elif [ "$TAILSCALE_STATUS" = "not installed" ]; then
  log_warn "Not installed"
else
  log_warn "$TAILSCALE_STATUS"
fi

# Healthcheck timer
echo -n "  Healthcheck Timer:    "
TIMER_STATUS=$(ssh_exec "$INSTANCE_NAME" "systemctl is-active openclaw-healthcheck.timer 2>/dev/null || systemctl --user is-active openclaw-healthcheck.timer 2>/dev/null || echo 'inactive'" 2>/dev/null)
if [ "$TIMER_STATUS" = "active" ]; then
  log_success "Active"
else
  log_warn "$TIMER_STATUS"
fi

# UFW firewall
echo -n "  UFW Firewall:         "
UFW_STATUS=$(ssh_exec "$INSTANCE_NAME" "ufw status 2>/dev/null | head -n1 | grep -o 'active' || echo 'inactive'" 2>/dev/null)
if [ "$UFW_STATUS" = "active" ]; then
  log_success "Active"
else
  log_warn "Inactive"
fi

# Disk space
echo -n "  Disk Space:           "
DISK_USAGE=$(ssh_exec "$INSTANCE_NAME" "df -h / | tail -1 | awk '{print \$5}' | tr -d '%'" 2>/dev/null)
DISK_FREE=$((100 - DISK_USAGE))
if [ "$DISK_FREE" -gt 50 ]; then
  log_success "${DISK_FREE}% free"
elif [ "$DISK_FREE" -gt 20 ]; then
  log_warn "${DISK_FREE}% free"
else
  log_error "${DISK_FREE}% free (low)"
fi

# Memory usage
echo -n "  Memory Usage:         "
MEM_USAGE=$(ssh_exec "$INSTANCE_NAME" "free | grep Mem | awk '{printf \"%.0f\", \$3/\$2 * 100}'" 2>/dev/null)
if [ "$MEM_USAGE" -lt 90 ]; then
  log_success "${MEM_USAGE}%"
else
  log_error "${MEM_USAGE}% (high)"
fi

# Tool stack — batch all checks in one SSH call to minimize round-trips
echo ""
echo "Tool Stack:"
TOOL_STACK_MISSING=false

TOOL_CHECK=$(ssh_exec "$INSTANCE_NAME" "bash -c '
  # proactive-amcp: prefer git hash from skill dir, fall back to which
  PAMCP_DIR=\$HOME/.openclaw/skills/proactive-amcp
  if [ -d \"\$PAMCP_DIR/.git\" ]; then
    echo \"pamcp:git:\$(cd \"\$PAMCP_DIR\" && git rev-parse --short HEAD 2>/dev/null || echo unknown)\"
  elif command -v proactive-amcp &>/dev/null; then
    echo \"pamcp:bin:\$(proactive-amcp --version 2>/dev/null || echo installed)\"
  else
    echo \"pamcp:missing\"
  fi
  # Claude Code CLI
  if command -v claude &>/dev/null; then
    echo \"claude:ok:\$(claude --version 2>/dev/null | head -1 || echo installed)\"
  else
    echo \"claude:missing\"
  fi
  # Solvr skill
  if [ -f \"\$HOME/.claude/skills/solvr/SKILL.md\" ] || [ -d \"\$HOME/.claude/skills/solvr/scripts\" ]; then
    echo \"solvr:ok\"
  else
    echo \"solvr:missing\"
  fi
'" 2>/dev/null || echo "pamcp:error
claude:error
solvr:error")

# Parse batched results
PAMCP_LINE=$(echo "$TOOL_CHECK" | grep '^pamcp:')
CLAUDE_LINE=$(echo "$TOOL_CHECK" | grep '^claude:')
SOLVR_LINE=$(echo "$TOOL_CHECK" | grep '^solvr:')

echo -n "  proactive-amcp:       "
case "$PAMCP_LINE" in
  pamcp:git:*)  log_success "${PAMCP_LINE#pamcp:git:}" ;;
  pamcp:bin:*)  log_success "${PAMCP_LINE#pamcp:bin:}" ;;
  pamcp:missing) log_warn "Not installed"; TOOL_STACK_MISSING=true ;;
  *)            log_error "Check failed"; TOOL_STACK_MISSING=true ;;
esac

echo -n "  Claude Code CLI:      "
case "$CLAUDE_LINE" in
  claude:ok:*)  log_success "${CLAUDE_LINE#claude:ok:}" ;;
  claude:missing) log_warn "Not installed"; TOOL_STACK_MISSING=true ;;
  *)            log_error "Check failed"; TOOL_STACK_MISSING=true ;;
esac

echo -n "  Solvr skill:          "
case "$SOLVR_LINE" in
  solvr:ok)     log_success "Installed" ;;
  solvr:missing) log_warn "Not installed"; TOOL_STACK_MISSING=true ;;
  *)            log_error "Check failed"; TOOL_STACK_MISSING=true ;;
esac

# Recent logs
echo ""
echo "Recent Gateway Logs:"
ssh_exec "$INSTANCE_NAME" "journalctl -u openclaw-gateway -n 5 --no-pager 2>/dev/null || echo '  (no logs available)'" 2>/dev/null | sed 's/^/  /'

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo ""
echo "Quick Actions:"
echo "  SSH to instance:     claw ssh $INSTANCE_NAME"
echo "  View full logs:      claw logs $INSTANCE_NAME -f"
echo "  Restart gateway:     claw restart $INSTANCE_NAME"
echo "  Diagnose issues:     claw diagnose $INSTANCE_NAME"
if [ "$TOOL_STACK_MISSING" = true ]; then
  echo "  Upgrade tools:       claw upgrade $INSTANCE_NAME"
fi
echo ""
