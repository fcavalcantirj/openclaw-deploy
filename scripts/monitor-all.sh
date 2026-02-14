#!/usr/bin/env bash
set -euo pipefail

# monitor-all.sh - Check all OpenClaw instances and alert on issues
# Usage: ./scripts/monitor-all.sh [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

# Counters
TOTAL_INSTANCES=0
HEALTHY_INSTANCES=0
DEGRADED_INSTANCES=0
OFFLINE_INSTANCES=0
UNKNOWN_INSTANCES=0

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
  - VM connectivity via SSH
  - Gateway service status
  - OpenClaw CLI responsiveness
  - Recent error logs
  - Disk space

Status levels:
  HEALTHY     - All checks passed
  DEGRADED    - Gateway running but has issues
  OFFLINE     - Gateway not running
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
    -v|--verbose) VERBOSE=true; shift ;;
    -q|--quiet)   QUIET=true; shift ;;
    -j|--json)    JSON_OUTPUT=true; shift ;;
    -w|--watch)   WATCH_INTERVAL="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)            log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# Check instance health
check_instance() {
  local instance_name="$1"
  load_instance "$instance_name" 2>/dev/null || { echo "UNKNOWN"; return; }

  if [[ -z "$INSTANCE_SSH_KEY" || ! -f "$INSTANCE_SSH_KEY" ]]; then
    echo "UNKNOWN"
    return
  fi

  # Check SSH connectivity
  if ! ssh_check "$instance_name" 5 2>/dev/null; then
    echo "UNREACHABLE"
    return
  fi

  # Check gateway service
  local service_status
  service_status=$(ssh_exec "$instance_name" "systemctl is-active openclaw-gateway 2>&1" 2>/dev/null || echo "inactive")

  if [ "$service_status" != "active" ]; then
    echo "OFFLINE"
    return
  fi

  # Check OpenClaw CLI
  local cli_status
  cli_status=$(ssh_exec "$instance_name" "openclaw gateway status 2>&1 | grep -iq 'running\|active' && echo 'ok' || echo 'error'" 2>/dev/null)

  if [ "$cli_status" != "ok" ]; then
    echo "DEGRADED"
    return
  fi

  # Check for recent errors
  local error_count
  error_count=$(ssh_exec "$instance_name" "journalctl -u openclaw-gateway --since '10 minutes ago' -p err --no-pager 2>&1 | grep -c '^' || echo 0" 2>/dev/null)

  if [ "$error_count" -gt 5 ]; then
    echo "DEGRADED"
    return
  fi

  # Check disk space
  local disk_usage
  disk_usage=$(ssh_exec "$instance_name" "df -h / | tail -1 | awk '{print \$5}' | sed 's/%//'" 2>/dev/null || echo "0")

  if [ "$disk_usage" -gt 90 ]; then
    echo "DEGRADED"
    return
  fi

  echo "HEALTHY"
}

# Get detailed instance info
get_instance_details() {
  local instance_name="$1"
  load_instance "$instance_name" 2>/dev/null || return

  echo "Instance: $instance_name"
  echo "  IP: $INSTANCE_IP"
  echo "  Region: $INSTANCE_REGION"

  if ssh_check "$instance_name" 5 2>/dev/null; then
    local version
    version=$(ssh_exec "$instance_name" "openclaw --version 2>&1 | head -1" 2>/dev/null || echo "unknown")
    local uptime_info
    uptime_info=$(ssh_exec "$instance_name" "uptime -p" 2>/dev/null || echo "unknown")
    local disk
    disk=$(ssh_exec "$instance_name" "df -h / | tail -1 | awk '{print \$5\" used\"}'" 2>/dev/null || echo "unknown")

    echo "  OpenClaw: $version"
    echo "  Uptime: $uptime_info"
    echo "  Disk: $disk"
  else
    echo "  Status: Cannot connect"
  fi
}

# Perform monitoring sweep
monitor_sweep() {
  if [ "$JSON_OUTPUT" = false ] && [ "$QUIET" = false ]; then
    echo
    log_info "Monitoring all OpenClaw instances..."
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
      log_warn "No instances directory found"
    fi
    return
  fi

  local json_results="["
  local first_result=true

  for instance_dir in "$INSTANCES_DIR"/*; do
    if [ ! -d "$instance_dir" ] || [ ! -f "$instance_dir/metadata.json" ]; then
      continue
    fi

    local instance_name
    instance_name=$(basename "$instance_dir")
    TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))

    local status
    status=$(check_instance "$instance_name")

    case $status in
      HEALTHY)
        HEALTHY_INSTANCES=$((HEALTHY_INSTANCES + 1))
        if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
          echo -e "${GREEN}+ $instance_name${NC} - HEALTHY"
          get_instance_details "$instance_name" | sed 's/^/    /'
          echo
        fi
        ;;
      DEGRADED)
        DEGRADED_INSTANCES=$((DEGRADED_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${YELLOW}! $instance_name${NC} - DEGRADED"
          if [ "$VERBOSE" = true ]; then
            get_instance_details "$instance_name" | sed 's/^/    /'
            echo
          fi
        fi
        ;;
      OFFLINE)
        OFFLINE_INSTANCES=$((OFFLINE_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${RED}x $instance_name${NC} - OFFLINE"
          if [ "$VERBOSE" = true ]; then
            get_instance_details "$instance_name" | sed 's/^/    /'
            echo
          fi
        fi
        ;;
      UNREACHABLE)
        UNKNOWN_INSTANCES=$((UNKNOWN_INSTANCES + 1))
        if [ "$JSON_OUTPUT" = false ]; then
          echo -e "${RED}x $instance_name${NC} - UNREACHABLE"
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
      echo -e "  Degraded:           ${YELLOW}$DEGRADED_INSTANCES${NC} !"
    else
      echo -e "  Degraded:           ${CYAN}$DEGRADED_INSTANCES${NC}"
    fi

    if [ $OFFLINE_INSTANCES -gt 0 ]; then
      echo -e "  Offline:            ${RED}$OFFLINE_INSTANCES${NC} x"
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
      echo -e "${RED}CRITICAL: Some instances are offline or unreachable${NC}"
      echo
    elif [ $DEGRADED_INSTANCES -gt 0 ]; then
      echo -e "${YELLOW}WARNING: Some instances are degraded${NC}"
      echo
    elif [ $TOTAL_INSTANCES -eq 0 ]; then
      echo -e "${CYAN}No instances found to monitor${NC}"
      echo
    else
      echo -e "${GREEN}+ All instances healthy${NC}"
      echo
    fi

    # Suggestions
    if [ $TOTAL_INSTANCES -gt 0 ] && ([ $DEGRADED_INSTANCES -gt 0 ] || [ $OFFLINE_INSTANCES -gt 0 ]); then
      echo -e "${BLUE}Troubleshooting:${NC}"
      echo -e "  - Check specific instance: ${YELLOW}claw status <instance-name>${NC}"
      echo -e "  - View logs: ${YELLOW}claw logs <instance-name> -f${NC}"
      echo -e "  - Restart instance: ${YELLOW}claw restart <instance-name>${NC}"
      echo -e "  - Diagnose issues: ${YELLOW}claw diagnose <instance-name>${NC}"
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
