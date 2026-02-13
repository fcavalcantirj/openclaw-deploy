#!/usr/bin/env bash
# ============================================================================
# destroy.sh — Destroy an OpenClaw instance and clean up resources
# Usage: ./destroy.sh <instance-name> [--confirm]
# ============================================================================
set -euo pipefail

INSTANCE_NAME="${1:-}"
CONFIRM="${2:-}"
INSTANCES_DIR="$(dirname "$0")/../instances"
ARCHIVE_DIR="$INSTANCES_DIR/.archive"

if [ -z "$INSTANCE_NAME" ]; then
  echo "Usage: $0 <instance-name> [--confirm]"
  exit 1
fi

METADATA_FILE="$INSTANCES_DIR/$INSTANCE_NAME/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  echo "❌ Instance '$INSTANCE_NAME' not found"
  exit 1
fi

IP=$(jq -r '.ip // ""' "$METADATA_FILE")

echo "════════════════════════════════════════════════════════════════"
echo "  ⚠️  DESTROYING INSTANCE: $INSTANCE_NAME"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  This will:"
echo "  • Delete the Hetzner server"
echo "  • Remove SSH keys"
echo "  • Archive instance metadata"
echo ""

if [ "$CONFIRM" != "--confirm" ]; then
  read -p "  Type 'destroy' to confirm: " RESPONSE
  if [ "$RESPONSE" != "destroy" ]; then
    echo "  Aborted."
    exit 1
  fi
fi

echo ""
echo "Destroying..."

# Logout from Tailscale (if accessible)
if [ -n "$IP" ]; then
  echo "  Disconnecting Tailscale..."
  ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$IP" 'tailscale logout' 2>/dev/null || true
fi

# Delete Hetzner server
echo "  Deleting Hetzner server..."
hcloud server delete "$INSTANCE_NAME" 2>/dev/null || echo "  (server may already be deleted)"

# Delete SSH key from Hetzner
echo "  Removing SSH key from Hetzner..."
hcloud ssh-key delete "${INSTANCE_NAME}-key" 2>/dev/null || true

# Delete local SSH keys
echo "  Removing local SSH keys..."
rm -f "$HOME/.ssh/openclaw_${INSTANCE_NAME}"* 2>/dev/null || true

# Archive instance metadata
echo "  Archiving metadata..."
mkdir -p "$ARCHIVE_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mv "$INSTANCES_DIR/$INSTANCE_NAME" "$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}"

# Add destroyed_at to archived metadata
jq ". + {destroyed_at: \"$(date -Iseconds)\"}" \
  "$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}/metadata.json" > \
  "$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}/metadata.json.tmp" && \
  mv "$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}/metadata.json.tmp" \
     "$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}/metadata.json"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ Instance '$INSTANCE_NAME' destroyed"
echo "  📦 Metadata archived to: .archive/${INSTANCE_NAME}-${TIMESTAMP}/"
echo "════════════════════════════════════════════════════════════════"
