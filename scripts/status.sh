#!/usr/bin/env bash
# ============================================================================
# status.sh — Check status of an OpenClaw instance
# Usage: ./status.sh <instance-name>
# ============================================================================
set -euo pipefail

INSTANCE_NAME="${1:-}"
INSTANCES_DIR="$(dirname "$0")/../instances"

if [ -z "$INSTANCE_NAME" ]; then
  echo "Usage: $0 <instance-name>"
  echo ""
  echo "Available instances:"
  ls -1 "$INSTANCES_DIR" 2>/dev/null | grep -v '^\.archive$' || echo "  (none)"
  exit 1
fi

METADATA_FILE="$INSTANCES_DIR/$INSTANCE_NAME/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  echo "❌ Instance '$INSTANCE_NAME' not found"
  exit 1
fi

echo "════════════════════════════════════════════════════════════════"
echo "  Instance: $INSTANCE_NAME"
echo "════════════════════════════════════════════════════════════════"

# Parse metadata
IP=$(jq -r '.ip // "unknown"' "$METADATA_FILE")
REGION=$(jq -r '.region // "unknown"' "$METADATA_FILE")
STATUS=$(jq -r '.status // "unknown"' "$METADATA_FILE")
CREATED=$(jq -r '.created_at // "unknown"' "$METADATA_FILE")
TAILSCALE_IP=$(jq -r '.tailscale_ip // "not configured"' "$METADATA_FILE")

echo "  Status:       $STATUS"
echo "  IP:           $IP"
echo "  Tailscale:    $TAILSCALE_IP"
echo "  Region:       $REGION"
echo "  Created:      $CREATED"
echo ""

# Live checks if IP is available
if [ "$IP" != "unknown" ] && [ "$IP" != "null" ]; then
  echo "Live checks:"
  
  # SSH check
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "openclaw@$IP" 'echo ok' &>/dev/null; then
    echo "  ✓ SSH accessible"
    
    # Gateway check
    GATEWAY_STATUS=$(ssh -o ConnectTimeout=5 "openclaw@$IP" 'openclaw gateway status 2>&1' || echo "error")
    if echo "$GATEWAY_STATUS" | grep -qi "running"; then
      echo "  ✓ Gateway running"
    else
      echo "  ✗ Gateway not running"
    fi
    
    # Tailscale check
    TS_STATUS=$(ssh -o ConnectTimeout=5 "openclaw@$IP" 'tailscale status 2>&1' || echo "error")
    if echo "$TS_STATUS" | grep -qi "logged in"; then
      echo "  ✓ Tailscale connected"
    else
      echo "  ⚠ Tailscale status unclear"
    fi
  else
    echo "  ✗ SSH not accessible"
  fi
fi

echo "════════════════════════════════════════════════════════════════"
