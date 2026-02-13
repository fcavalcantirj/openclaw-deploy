#!/usr/bin/env bash
# ============================================================================
# list.sh — List all OpenClaw instances
# ============================================================================
set -euo pipefail

INSTANCES_DIR="$(dirname "$0")/../instances"

echo "════════════════════════════════════════════════════════════════"
echo "  OpenClaw Instances"
echo "════════════════════════════════════════════════════════════════"

if [ ! -d "$INSTANCES_DIR" ] || [ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null | grep -v '^\.archive$')" ]; then
  echo "  No instances found."
  echo ""
  echo "  Create one with: ./scripts/provision.sh --name <name>"
  exit 0
fi

printf "%-25s %-15s %-15s %-12s\n" "NAME" "IP" "STATUS" "REGION"
printf "%-25s %-15s %-15s %-12s\n" "────────────────────────" "──────────────" "──────────────" "───────────"

for dir in "$INSTANCES_DIR"/*/; do
  [ -d "$dir" ] || continue
  [[ "$(basename "$dir")" == ".archive" ]] && continue
  
  NAME=$(basename "$dir")
  METADATA="$dir/metadata.json"
  
  if [ -f "$METADATA" ]; then
    IP=$(jq -r '.ip // "-"' "$METADATA")
    STATUS=$(jq -r '.status // "-"' "$METADATA")
    REGION=$(jq -r '.region // "-"' "$METADATA")
  else
    IP="-"
    STATUS="no metadata"
    REGION="-"
  fi
  
  printf "%-25s %-15s %-15s %-12s\n" "$NAME" "$IP" "$STATUS" "$REGION"
done

echo "════════════════════════════════════════════════════════════════"
