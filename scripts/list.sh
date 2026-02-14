#!/bin/bash
set -euo pipefail

# list.sh - List all OpenClaw instances with status
# Usage: ./scripts/list.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

# Function to get status color
get_status_color() {
  local status=$1
  case "$status" in
    operational)              echo "$GREEN" ;;
    degraded)                 echo "$YELLOW" ;;
    provisioned|bootstrapped|openclaw-installed|tailscale-configured|skills-configured|monitoring-configured|imported)
                              echo "$CYAN" ;;
    *)                        echo "$RED" ;;
  esac
}

# Function to check if VM is reachable
check_reachable() {
  local name=$1
  load_instance "$name" 2>/dev/null || { echo "unknown"; return; }

  if [[ -z "$INSTANCE_SSH_KEY" || ! -f "$INSTANCE_SSH_KEY" ]]; then
    echo "unknown"
    return
  fi

  if ssh_check "$name" 3 2>/dev/null; then
    echo "online"
  else
    echo "offline"
  fi
}

# Header
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  OpenClaw Instances${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if instances directory exists
if [ ! -d "$INSTANCES_DIR" ]; then
  log_warn "No instances found (instances directory does not exist)"
  echo ""
  echo "To create an instance, run:"
  echo "  ./deploy.sh --name mybot --region nbg1 --anthropic-key YOUR_KEY"
  exit 0
fi

# Find all instance directories
INSTANCES=()
for dir in "$INSTANCES_DIR"/*; do
  if [ -d "$dir" ] && [ -f "$dir/metadata.json" ]; then
    INSTANCES+=("$(basename "$dir")")
  fi
done

# Check if any instances exist
if [ ${#INSTANCES[@]} -eq 0 ]; then
  log_warn "No instances found"
  echo ""
  echo "To create an instance, run:"
  echo "  ./deploy.sh --name mybot --region nbg1 --anthropic-key YOUR_KEY"
  exit 0
fi

# Print table header
printf "%-25s %-12s %-15s %-15s %-12s\n" "NAME" "STATUS" "SERVER IP" "TAILSCALE IP" "REACHABLE"
echo -e "${BLUE}───────────────────────────────────────────────────────────────────────────────${NC}"

# Iterate through instances
for instance in "${INSTANCES[@]}"; do
  load_instance "$instance" 2>/dev/null || continue

  METADATA_FILE="$INSTANCES_DIR/$instance/metadata.json"
  NAME=$instance
  STATUS="$INSTANCE_STATUS"
  SERVER_IP="$INSTANCE_IP"
  TAILSCALE_IP=$(jq -r '.tailscale_ip // "not set"' "$METADATA_FILE")

  # Check reachability
  REACHABLE=$(check_reachable "$instance")

  # Get status color
  STATUS_COLOR=$(get_status_color "$STATUS")

  # Determine reachable color
  case "$REACHABLE" in
    online)  REACHABLE_COLOR="$GREEN"; REACHABLE_ICON="+" ;;
    offline) REACHABLE_COLOR="$RED";   REACHABLE_ICON="x" ;;
    *)       REACHABLE_COLOR="$YELLOW"; REACHABLE_ICON="?" ;;
  esac

  # Print row
  printf "%-25s " "$NAME"
  printf "${STATUS_COLOR}%-12s${NC} " "$STATUS"
  printf "%-15s " "$SERVER_IP"
  printf "%-15s " "$TAILSCALE_IP"
  printf "${REACHABLE_COLOR}${REACHABLE_ICON} %-10s${NC}\n" "$REACHABLE"
done

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Commands:"
echo "  View details:        claw status <instance-name>"
echo "  Import existing:     claw import <name> <ip> <ssh-key>"
echo "  Destroy instance:    claw destroy <instance-name>"
echo "  Deploy new:          claw deploy --name mybot --bot-token TOKEN"
echo ""

# Show summary
TOTAL=${#INSTANCES[@]}
OPERATIONAL=0
DEGRADED=0
OFFLINE=0

for instance in "${INSTANCES[@]}"; do
  REACHABLE=$(check_reachable "$instance")
  load_instance "$instance" 2>/dev/null || continue

  if [ "$INSTANCE_STATUS" = "operational" ] && [ "$REACHABLE" = "online" ]; then
    OPERATIONAL=$((OPERATIONAL + 1))
  elif [ "$REACHABLE" = "offline" ]; then
    OFFLINE=$((OFFLINE + 1))
  elif [ "$INSTANCE_STATUS" = "degraded" ]; then
    DEGRADED=$((DEGRADED + 1))
  fi
done

echo "Summary:"
echo "  Total instances:     $TOTAL"
echo -e "  ${GREEN}Operational:         $OPERATIONAL${NC}"
if [ $DEGRADED -gt 0 ]; then
  echo -e "  ${YELLOW}Degraded:            $DEGRADED${NC}"
fi
if [ $OFFLINE -gt 0 ]; then
  echo -e "  ${RED}Offline:             $OFFLINE${NC}"
fi
echo ""
