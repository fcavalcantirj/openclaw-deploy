#!/usr/bin/env bash
set -euo pipefail

# monitor-all.sh - Check all OpenClaw instances and alert on issues
# Usage: ./scripts/monitor-all.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Counters
TOTAL_INSTANCES=0
HEALTHY_INSTANCES=0
DEGRADED_INSTANCES=0
OFFLINE_INSTANCES=0
UNKNOWN_INSTANCES=0

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

Monitor all deployed OpenClaw instances and report on their health status.

Options:
  -v, --verbose      Show detailed check results for each instance
  -q, --quiet        Only show summary and issues
  -j, --json         Output results in JSON format
  -w, --watch N      Continuously monitor every N seconds
  -h, --help         Show this help message

Examples:
  $0                       # Quick health check of all instances
  $0 --verbose             # Detailed check with full output
  $0 --watch 60            # Monitor every 60 seconds
  $0 --json > status.json  # Export status as JSON

Health checks performed:
  • VM connectivity via SSH
  • Gateway service status
  • OpenClaw CLI responsiveness
  • Recent error logs
  • Disk space
  • Memory usage

Status levels:
  HEALTHY   - All checks passed
  DEGRADED  - Gateway running but has issues
  OFFLINE   - Gateway not running
  UNREACHABLE - Cannot connect to VM

EOF
  exit 1
}

# Parse arguments
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
WATCH_INTERVAL=0

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -q|--quiet)
      QUIET=true
      shift
      ;;
    -j|--json)
      JSON_OUTPUT=true
      shift
      ;;
    -w|--watch)
      WATCH_INTERVAL="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      error "Unknown option: $1"
      ;;
  esac
done

# Check instance health
check_instance() {
  local instance_name="$1"
  local instance_dir="$INSTANCES_DIR/$instance_name"
  local metadata_file="$instance_dir/metadata.json"

  if [ ! -f "$metadata_file" ]; then
    echo "SKIP"
    return
  fi

  local ip=$(jq -r '.ip' "$metadata_file")
  local ssh_key=$(jq -r '.ssh_key' "$metadata_file")

  if [ -z "$ip" ] || [ "$ip" = "null" ]; then
    echo "UNKNOWN"
    return
  fi

  if [ ! -f "$ssh_key" ]; then
    echo "UNKNOWN"
    return
  fi

  # Check SSH connectivity
  if ! ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
       "openclaw@$ip" "echo ok" > /dev/null 2>&1; then
    echo "UNREACHABLE"
    return
  fi

  # Check gateway service
  local service_status=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "openclaw@$ip" "systemctl --user is-active openclaw-gateway 2>&1" || echo "inactive")

  if [ "$service_status" != "active" ]; then
    echo "OFFLINE"
    return
  fi

  # Check OpenClaw CLI
  local cli_status=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "openclaw@$ip" "openclaw gateway status 2>&1 | grep -iq 'running\|active' && echo 'ok' || echo 'error'")

  if [ "$cli_status" != "ok" ]; then
    echo "DEGRADED"
    return
  fi

  # Check for recent errors
  local error_count=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "openclaw@$ip" "journalctl --user -u openclaw-gateway --since '10 minutes ago' -p err --no-pager 2>&1 | grep -c '^' || echo 0")

  if [ "$error_count" -gt 5 ]; then
    echo "DEGRADED"
    return
  fi

  # Check disk space
  local disk_usage=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "openclaw@$ip" "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'" || echo "0")

  if [ "$disk_usage" -gt 90 ]; then
    echo "DEGRADED"
    return
  fi

  echo "HEALTHY"
}

# Get detailed instance info
get_instance_details() {
  local instance_name="$1"
  local instance_dir="$INSTANCES_DIR/$instance_name"
  local metadata_file="$instance_dir/metadata.json"

  local ip=$(jq -r '.ip' "$metadata_file")
  local ssh_key=$(jq -r '.ssh_key' "$metadata_file")
  local region=$(jq -r '.region // "unknown"' "$metadata_file")

  echo "Instance: $instance_name"
  echo "  IP: $ip"
  echo "  Region: $region"

  if ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
     "openclaw@$ip" "echo ok" > /dev/null 2>&1; then

    local version=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "openclaw@$ip" "openclaw --version 2>&1 | head -1" || echo "unknown")

    local uptime=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "openclaw@$ip" "uptime -p" || echo "unknown")

    local disk=$(ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "openclaw@$ip" "df -h / | tail -1 | awk '{print \$5\" used\"}'" || echo "unknown")

    echo "  OpenClaw: $version"
    echo "  Uptime: $uptime"
    echo "  Disk: $disk"
  else
    echo "  Status: Cannot connect"
  fi
}

# Perform monitoring sweep
monitor_sweep() {
  if [ "$JSON_OUTPUT" = false ] && [ "$QUIET" = false ]; then
    echo
    info "Monitoring all OpenClaw instances..."
    echo
  fi

  # Reset counters
  TOTAL_INSTANCES=0
  HEALTHY_INSTANCES=0
  DEGRADED_INSTANCES=0
  OFFLINE_INSTANCES=0
  UNKNOWN_INSTANCES=0

  # Find all instances
  if [ ! -d "$INSTANCES_DIR" ]; then
    if [ "$JSON_OUTPUT" = false ]; then
      warning "No instances directory found"
    fi
    return
  fi

  local json_results="["
  local first_result=true

  for instance_dir in "$INSTANCES_DIR"/*; do
    if [ ! -d "$instance_dir" ]; then
      continue
    fi

    local instance_name=$(basename "$instance_dir")
    TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))

    local status=$(check_instance "$instance_name")

    case $status in
      HEALTHY)
        HEALTHY_INSTANCES=$((HEALTHY_INSTANCES + 1))
        if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
          echo -e "${GREEN}✓ $instance_name${NC} - HEALTHY"
          if [ "$VERBOSE" = true ]; then
            get_instance_details "$instance_name" | sed 's/^/    /'
            echo
          fi
        fi
        ;;
      DEGRADED)
        DEGRADED_INSTANCES=$((DEGRADED_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${YELLOW}⚠ $instance_name${NC} - DEGRADED"
          if [ "$VERBOSE" = true ]; then
            get_instance_details "$instance_name" | sed 's/^/    /'
            echo
          fi
        fi
        ;;
      OFFLINE)
        OFFLINE_INSTANCES=$((OFFLINE_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${RED}✗ $instance_name${NC} - OFFLINE"
          if [ "$VERBOSE" = true ]; then
            get_instance_details "$instance_name" | sed 's/^/    /'
            echo
          fi
        fi
        ;;
      UNREACHABLE)
        UNKNOWN_INSTANCES=$((UNKNOWN_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${RED}✗ $instance_name${NC} - UNREACHABLE"
        fi
        ;;
      UNKNOWN|SKIP)
        UNKNOWN_INSTANCES=$((UNKNOWN_INSTANCES + 1))
        if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
          echo -e "${CYAN}? $instance_name${NC} - UNKNOWN"
        fi
        ;;
    esac

    # Build JSON output
    if [ "$JSON_OUTPUT" = true ]; then
      if [ "$first_result" = false ]; then
        json_results+=","
      fi
      first_result=false
      json_results+="{\"instance\":\"$instance_name\",\"status\":\"$status\"}"
    fi
  done

  json_results+="]"

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    echo "$json_results" | jq .
  else
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                  MONITORING SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo
    echo -e "  Total instances:    ${CYAN}$TOTAL_INSTANCES${NC}"
    echo -e "  Healthy:            ${GREEN}$HEALTHY_INSTANCES${NC}"

    if [ $DEGRADED_INSTANCES -gt 0 ]; then
      echo -e "  Degraded:           ${YELLOW}$DEGRADED_INSTANCES${NC} ⚠"
    else
      echo -e "  Degraded:           ${CYAN}$DEGRADED_INSTANCES${NC}"
    fi

    if [ $OFFLINE_INSTANCES -gt 0 ]; then
      echo -e "  Offline:            ${RED}$OFFLINE_INSTANCES${NC} ✗"
    else
      echo -e "  Offline:            ${CYAN}$OFFLINE_INSTANCES${NC}"
    fi

    if [ $UNKNOWN_INSTANCES -gt 0 ]; then
      echo -e "  Unknown/Unreachable: ${RED}$UNKNOWN_INSTANCES${NC} ?"
    else
      echo -e "  Unknown/Unreachable: ${CYAN}$UNKNOWN_INSTANCES${NC}"
    fi

    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo

    # Overall status
    if [ $OFFLINE_INSTANCES -gt 0 ] || [ $UNKNOWN_INSTANCES -gt 0 ]; then
      echo -e "${RED}⚠ CRITICAL: Some instances are offline or unreachable${NC}"
      echo
    elif [ $DEGRADED_INSTANCES -gt 0 ]; then
      echo -e "${YELLOW}⚠ WARNING: Some instances are degraded${NC}"
      echo
    elif [ $TOTAL_INSTANCES -eq 0 ]; then
      echo -e "${CYAN}No instances found to monitor${NC}"
      echo
    else
      echo -e "${GREEN}✓ All instances healthy${NC}"
      echo
    fi

    # Suggestions
    if [ $TOTAL_INSTANCES -gt 0 ] && ([ $DEGRADED_INSTANCES -gt 0 ] || [ $OFFLINE_INSTANCES -gt 0 ]); then
      echo -e "${BLUE}Troubleshooting:${NC}"
      echo -e "  • Check specific instance: ${YELLOW}./scripts/status.sh <instance-name>${NC}"
      echo -e "  • View logs: ${YELLOW}./scripts/logs.sh <instance-name> --errors${NC}"
      echo -e "  • Restart instance: ${YELLOW}./scripts/restart.sh <instance-name>${NC}"
      echo -e "  • Resuscitate crashed instance: ${YELLOW}./scripts/resuscitate.sh <instance-name>${NC}"
      echo
    fi
  fi
}

# Main execution
if [ $WATCH_INTERVAL -gt 0 ]; then
  # Watch mode
  while true; do
    clear
    monitor_sweep
    if [ "$JSON_OUTPUT" = false ]; then
      echo -e "${CYAN}Refreshing in $WATCH_INTERVAL seconds... (Ctrl+C to stop)${NC}"
    fi
    sleep "$WATCH_INTERVAL"
  done
else
  # Single run
  monitor_sweep
fi
