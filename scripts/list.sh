#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Function to print colored output
print_color() {
  local color=$1
  local message=$2
  echo -e "${color}${message}${NC}"
}

# Function to get status color
get_status_color() {
  local status=$1
  case "$status" in
    operational)
      echo "$GREEN"
      ;;
    degraded)
      echo "$YELLOW"
      ;;
    provisioned|bootstrapped|openclaw-installed|tailscale-configured|skills-configured|monitoring-configured)
      echo "$CYAN"
      ;;
    *)
      echo "$RED"
      ;;
  esac
}

# Function to check if VM is reachable
check_reachable() {
  local ssh_key=$1
  local ip=$2
  
  if [ -z "$ssh_key" ] || [ ! -f "$ssh_key" ]; then
    echo "unknown"
    return
  fi
  
  if timeout 3 ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=3 "openclaw@$ip" "exit" 2>/dev/null; then
    echo "online"
  else
    echo "offline"
  fi
}

# Header
print_color "$BLUE" "═══════════════════════════════════════════════════════════════════════════════"
print_color "$BLUE" "  OpenClaw Instances"
print_color "$BLUE" "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Check if instances directory exists
if [ ! -d "$INSTANCES_DIR" ]; then
  print_color "$YELLOW" "No instances found (instances directory does not exist)"
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
  print_color "$YELLOW" "No instances found"
  echo ""
  echo "To create an instance, run:"
  echo "  ./deploy.sh --name mybot --region nbg1 --anthropic-key YOUR_KEY"
  exit 0
fi

# Print table header
printf "%-25s %-12s %-15s %-15s %-12s\n" "NAME" "STATUS" "SERVER IP" "TAILSCALE IP" "REACHABLE"
print_color "$BLUE" "───────────────────────────────────────────────────────────────────────────────"

# Iterate through instances
for instance in "${INSTANCES[@]}"; do
  METADATA_FILE="$INSTANCES_DIR/$instance/metadata.json"
  
  # Read metadata
  NAME=$instance
  STATUS=$(jq -r '.status // "unknown"' "$METADATA_FILE")
  SERVER_IP=$(jq -r '.ip // "unknown"' "$METADATA_FILE")
  TAILSCALE_IP=$(jq -r '.tailscale_ip // "not set"' "$METADATA_FILE")
  SSH_KEY=$(jq -r '.ssh_key // ""' "$METADATA_FILE")
  
  # Check reachability
  REACHABLE=$(check_reachable "$SSH_KEY" "$SERVER_IP")
  
  # Get status color
  STATUS_COLOR=$(get_status_color "$STATUS")
  
  # Determine reachable color
  case "$REACHABLE" in
    online)
      REACHABLE_COLOR="$GREEN"
      REACHABLE_ICON="✓"
      ;;
    offline)
      REACHABLE_COLOR="$RED"
      REACHABLE_ICON="✗"
      ;;
    *)
      REACHABLE_COLOR="$YELLOW"
      REACHABLE_ICON="?"
      ;;
  esac
  
  # Print row
  printf "%-25s " "$NAME"
  printf "${STATUS_COLOR}%-12s${NC} " "$STATUS"
  printf "%-15s " "$SERVER_IP"
  printf "%-15s " "$TAILSCALE_IP"
  printf "${REACHABLE_COLOR}${REACHABLE_ICON} %-10s${NC}\n" "$REACHABLE"
done

echo ""
print_color "$BLUE" "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Commands:"
echo "  View details:        ./scripts/status.sh <instance-name>"
echo "  Destroy instance:    ./scripts/destroy.sh <instance-name> --confirm"
echo "  Deploy new:          ./deploy.sh --name mybot --region nbg1 --anthropic-key YOUR_KEY"
echo ""

# Show summary
TOTAL=${#INSTANCES[@]}
OPERATIONAL=0
DEGRADED=0
OFFLINE=0

for instance in "${INSTANCES[@]}"; do
  METADATA_FILE="$INSTANCES_DIR/$instance/metadata.json"
  STATUS=$(jq -r '.status // "unknown"' "$METADATA_FILE")
  SERVER_IP=$(jq -r '.ip // "unknown"' "$METADATA_FILE")
  SSH_KEY=$(jq -r '.ssh_key // ""' "$METADATA_FILE")
  REACHABLE=$(check_reachable "$SSH_KEY" "$SERVER_IP")
  
  if [ "$STATUS" = "operational" ] && [ "$REACHABLE" = "online" ]; then
    OPERATIONAL=$((OPERATIONAL + 1))
  elif [ "$STATUS" = "degraded" ] || [ "$REACHABLE" = "offline" ]; then
    if [ "$REACHABLE" = "offline" ]; then
      OFFLINE=$((OFFLINE + 1))
    else
      DEGRADED=$((DEGRADED + 1))
    fi
  fi
done

echo "Summary:"
echo "  Total instances:     $TOTAL"
print_color "$GREEN" "  Operational:         $OPERATIONAL"
if [ $DEGRADED -gt 0 ]; then
  print_color "$YELLOW" "  Degraded:            $DEGRADED"
fi
if [ $OFFLINE -gt 0 ]; then
  print_color "$RED" "  Offline:             $OFFLINE"
fi
echo ""
