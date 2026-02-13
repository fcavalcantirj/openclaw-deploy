#!/usr/bin/env bash
set -euo pipefail

# setup-monitoring-cron.sh - Set up automated fleet monitoring with cron
# Usage: ./scripts/setup-monitoring-cron.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default settings
INTERVAL=5  # minutes
ALERT_EMAIL=""
ALERT_TELEGRAM=""
LOG_FILE="$PROJECT_ROOT/fleet-monitor.log"
STATUS_FILE="/tmp/openclaw-fleet-status.json"

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

warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

usage() {
  cat << EOF
Usage: $0 [options]

Set up automated monitoring of all child OpenClaw instances using cron.

Options:
  -i, --interval N     Check interval in minutes (default: 5)
  -e, --email ADDR     Send alerts to email address
  -t, --telegram URL   Send alerts to Telegram webhook URL
  -l, --log FILE       Log file path (default: fleet-monitor.log)
  --uninstall          Remove cron monitoring
  -h, --help           Show this help message

Examples:
  $0                                    # Set up with defaults (5 min interval)
  $0 --interval 10                      # Check every 10 minutes
  $0 --email admin@example.com          # Email alerts
  $0 --telegram https://api.telegram... # Telegram alerts
  $0 --uninstall                        # Remove monitoring

What this does:
  1. Creates monitoring script in project directory
  2. Adds cron job to check fleet health periodically
  3. Logs results to file
  4. Sends alerts when instances are degraded/offline
  5. Can be configured for email or Telegram alerts

EOF
  exit 1
}

# Parse arguments
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -i|--interval)
      INTERVAL="$2"
      shift 2
      ;;
    -e|--email)
      ALERT_EMAIL="$2"
      shift 2
      ;;
    -t|--telegram)
      ALERT_TELEGRAM="$2"
      shift 2
      ;;
    -l|--log)
      LOG_FILE="$2"
      shift 2
      ;;
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      error "Unknown option: $1"
      ;;
  esac
done

# Uninstall mode
if [ "$UNINSTALL" = true ]; then
  echo
  info "Removing fleet monitoring cron job..."

  # Remove from crontab
  if crontab -l 2>/dev/null | grep -q "openclaw-deploy.*monitor-all.sh"; then
    crontab -l 2>/dev/null | grep -v "openclaw-deploy.*monitor-all.sh" | crontab -
    success "Cron job removed"
  else
    warning "No monitoring cron job found"
  fi

  # Remove monitoring wrapper if exists
  if [ -f "$PROJECT_ROOT/scripts/.monitor-wrapper.sh" ]; then
    rm "$PROJECT_ROOT/scripts/.monitor-wrapper.sh"
    success "Monitoring wrapper removed"
  fi

  echo
  success "Monitoring uninstalled"
  echo
  exit 0
fi

# Install mode
echo
info "Setting up automated fleet monitoring"
info "Check interval: every $INTERVAL minutes"
if [ -n "$ALERT_EMAIL" ]; then
  info "Email alerts: $ALERT_EMAIL"
fi
if [ -n "$ALERT_TELEGRAM" ]; then
  info "Telegram alerts: enabled"
fi
info "Log file: $LOG_FILE"
echo

# Validate interval
if [ "$INTERVAL" -lt 1 ] || [ "$INTERVAL" -gt 1440 ]; then
  error "Interval must be between 1 and 1440 minutes"
fi

# Check if monitor-all.sh exists
if [ ! -f "$SCRIPT_DIR/monitor-all.sh" ]; then
  error "monitor-all.sh not found. This script requires monitor-all.sh to exist."
fi

# Create monitoring wrapper script
WRAPPER_SCRIPT="$SCRIPT_DIR/.monitor-wrapper.sh"

cat > "$WRAPPER_SCRIPT" << 'EOF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

# Auto-generated monitoring wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EOF_WRAPPER

# Add configuration
cat >> "$WRAPPER_SCRIPT" << EOF_CONFIG
LOG_FILE="$LOG_FILE"
STATUS_FILE="$STATUS_FILE"
ALERT_EMAIL="$ALERT_EMAIL"
ALERT_TELEGRAM="$ALERT_TELEGRAM"
EOF_CONFIG

# Add monitoring logic
cat >> "$WRAPPER_SCRIPT" << 'EOF_LOGIC'

# Run monitor-all.sh
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP] Running fleet health check..." >> "$LOG_FILE"

"$SCRIPT_DIR/monitor-all.sh" --json > "$STATUS_FILE" 2>> "$LOG_FILE"

# Check for issues
DEGRADED=$(jq -r '.[] | select(.status == "DEGRADED") | .instance' "$STATUS_FILE" 2>/dev/null || echo "")
OFFLINE=$(jq -r '.[] | select(.status == "OFFLINE") | .instance' "$STATUS_FILE" 2>/dev/null || echo "")
UNREACHABLE=$(jq -r '.[] | select(.status == "UNREACHABLE") | .instance' "$STATUS_FILE" 2>/dev/null || echo "")

# Count issues
ISSUE_COUNT=0
if [ -n "$DEGRADED" ]; then
  ISSUE_COUNT=$((ISSUE_COUNT + $(echo "$DEGRADED" | wc -l)))
fi
if [ -n "$OFFLINE" ]; then
  ISSUE_COUNT=$((ISSUE_COUNT + $(echo "$OFFLINE" | wc -l)))
fi
if [ -n "$UNREACHABLE" ]; then
  ISSUE_COUNT=$((ISSUE_COUNT + $(echo "$UNREACHABLE" | wc -l)))
fi

if [ $ISSUE_COUNT -eq 0 ]; then
  echo "[$TIMESTAMP] All instances healthy" >> "$LOG_FILE"
  exit 0
fi

# Issues detected - send alerts
ALERT_MSG="OpenClaw Fleet Alert: $ISSUE_COUNT instance(s) need attention

DEGRADED:
$DEGRADED

OFFLINE:
$OFFLINE

UNREACHABLE:
$UNREACHABLE

View details: $STATUS_FILE
Run: $SCRIPT_DIR/monitor-all.sh --verbose"

echo "[$TIMESTAMP] ALERT: $ISSUE_COUNT issue(s) detected" >> "$LOG_FILE"
echo "$ALERT_MSG" >> "$LOG_FILE"

# Send email alert
if [ -n "$ALERT_EMAIL" ]; then
  if command -v mail &> /dev/null; then
    echo "$ALERT_MSG" | mail -s "OpenClaw Fleet Alert" "$ALERT_EMAIL" 2>> "$LOG_FILE" || true
    echo "[$TIMESTAMP] Email alert sent to $ALERT_EMAIL" >> "$LOG_FILE"
  else
    echo "[$TIMESTAMP] WARNING: mail command not found, cannot send email" >> "$LOG_FILE"
  fi
fi

# Send Telegram alert
if [ -n "$ALERT_TELEGRAM" ]; then
  if command -v curl &> /dev/null; then
    ESCAPED_MSG=$(echo "$ALERT_MSG" | jq -Rs .)
    curl -X POST "$ALERT_TELEGRAM" \
      -H "Content-Type: application/json" \
      -d "{\"text\": $ESCAPED_MSG}" \
      >> "$LOG_FILE" 2>&1 || true
    echo "[$TIMESTAMP] Telegram alert sent" >> "$LOG_FILE"
  else
    echo "[$TIMESTAMP] WARNING: curl not found, cannot send Telegram alert" >> "$LOG_FILE"
  fi
fi
EOF_LOGIC

chmod +x "$WRAPPER_SCRIPT"
success "Monitoring wrapper created"

# Add to crontab
info "Adding cron job..."

# Build cron entry
CRON_SCHEDULE="*/$INTERVAL * * * *"
CRON_COMMAND="$WRAPPER_SCRIPT"
CRON_ENTRY="$CRON_SCHEDULE $CRON_COMMAND"

# Check if already exists
if crontab -l 2>/dev/null | grep -q "$WRAPPER_SCRIPT"; then
  warning "Cron job already exists, updating..."
  # Remove old entry
  crontab -l 2>/dev/null | grep -v "$WRAPPER_SCRIPT" | crontab -
fi

# Add new entry
(crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -

success "Cron job added"

echo
success "Automated monitoring configured!"
echo

# Summary
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}            MONITORING CONFIGURATION${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo
echo -e "  Check interval:     ${GREEN}Every $INTERVAL minutes${NC}"
echo -e "  Log file:           ${YELLOW}$LOG_FILE${NC}"
echo -e "  Status file:        ${YELLOW}$STATUS_FILE${NC}"

if [ -n "$ALERT_EMAIL" ]; then
  echo -e "  Email alerts:       ${GREEN}$ALERT_EMAIL${NC}"
else
  echo -e "  Email alerts:       ${YELLOW}Disabled${NC}"
fi

if [ -n "$ALERT_TELEGRAM" ]; then
  echo -e "  Telegram alerts:    ${GREEN}Enabled${NC}"
else
  echo -e "  Telegram alerts:    ${YELLOW}Disabled${NC}"
fi

echo
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

# Next steps
echo -e "${BLUE}Management commands:${NC}"
echo -e "  • View current cron: ${YELLOW}crontab -l | grep openclaw${NC}"
echo -e "  • View log file: ${YELLOW}tail -f $LOG_FILE${NC}"
echo -e "  • View latest status: ${YELLOW}jq . $STATUS_FILE${NC}"
echo -e "  • Test manually: ${YELLOW}$WRAPPER_SCRIPT${NC}"
echo -e "  • Uninstall: ${YELLOW}$0 --uninstall${NC}"
echo

# Test run
warning "Running initial health check..."
echo

"$WRAPPER_SCRIPT" || true

echo
success "Initial check complete. Results logged to: $LOG_FILE"
echo

# Show cron confirmation
echo -e "${BLUE}Cron entry added:${NC}"
crontab -l | grep "$WRAPPER_SCRIPT"
echo
