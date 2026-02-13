#!/usr/bin/env bash
# ============================================================================
# destroy.sh — Destroy an OpenClaw instance and clean up resources
# Usage: ./destroy.sh <instance-name> [--confirm]
# ============================================================================
set -euo pipefail

INSTANCE_NAME="${1:-}"
CONFIRM="${2:-}"
INSTANCES_DIR="$(cd "$(dirname "$0")/.." && pwd)/instances"
ARCHIVE_DIR="$INSTANCES_DIR/.archive"

if [ -z "$INSTANCE_NAME" ]; then
  echo "Usage: $0 <instance-name> [--confirm]"
  exit 1
fi

METADATA_FILE="$INSTANCES_DIR/$INSTANCE_NAME/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  echo "❌ Instance '$INSTANCE_NAME' not found"
  echo ""
  echo "Available instances:"
  ls -1 "$INSTANCES_DIR" 2>/dev/null | grep -v "^\.archive$" || echo "  (none)"
  exit 1
fi

IP=$(jq -r '.ip // ""' "$METADATA_FILE")
SSH_KEY_PATH=$(jq -r '.ssh_key_path // ""' "$METADATA_FILE")
SSH_KEY_NAME="openclaw-${INSTANCE_NAME}"

echo "════════════════════════════════════════════════════════════════"
echo "  ⚠️  DESTROYING INSTANCE: $INSTANCE_NAME"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  Instance IP:  $IP"
echo "  SSH Key:      $SSH_KEY_PATH"
echo ""
echo "  This will:"
echo "  • Logout from Tailscale on the VM"
echo "  • Delete the Hetzner server ($INSTANCE_NAME)"
echo "  • Remove SSH key from Hetzner ($SSH_KEY_NAME)"
echo "  • Delete local SSH keys"
echo "  • Archive instance metadata to .archive/"
echo ""

if [ "$CONFIRM" != "--confirm" ]; then
  read -p "  Type 'destroy' to confirm: " RESPONSE
  if [ "$RESPONSE" != "destroy" ]; then
    echo "  Aborted."
    exit 1
  fi
fi

echo ""
echo "🗑️  Destroying instance..."
echo ""

# Logout from Tailscale (if accessible)
if [ -n "$IP" ] && [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
  echo "  Attempting to logout from Tailscale..."
  if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes "openclaw@$IP" 'tailscale logout' 2>/dev/null; then
    echo "  ✓ Tailscale logout successful"
  else
    echo "  ⚠ Could not logout from Tailscale (VM may be offline)"
  fi
  echo ""
fi

# Delete Hetzner server
echo "  Deleting Hetzner server '$INSTANCE_NAME'..."
if hcloud server describe "$INSTANCE_NAME" &>/dev/null; then
  hcloud server delete "$INSTANCE_NAME"
  echo "  ✓ Server deleted"
else
  echo "  ⚠ Server not found (may already be deleted)"
fi
echo ""

# Delete SSH key from Hetzner
echo "  Removing SSH key from Hetzner..."
if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  hcloud ssh-key delete "$SSH_KEY_NAME"
  echo "  ✓ SSH key '$SSH_KEY_NAME' deleted"
else
  echo "  ⚠ SSH key not found (may already be deleted)"
fi
echo ""

# Delete local SSH keys
echo "  Removing local SSH keys..."
if [ -n "$SSH_KEY_PATH" ]; then
  rm -f "${SSH_KEY_PATH}" "${SSH_KEY_PATH}.pub" 2>/dev/null || true
  echo "  ✓ Local SSH keys removed"
else
  echo "  ⚠ SSH key path not found in metadata"
fi
echo ""

# Archive instance metadata
echo "  Archiving metadata..."
mkdir -p "$ARCHIVE_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE_PATH="$ARCHIVE_DIR/${INSTANCE_NAME}-${TIMESTAMP}"

# Add destroyed_at to metadata before archiving
if [ -f "$METADATA_FILE" ]; then
  jq ". + {destroyed_at: \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" \
    "$METADATA_FILE" > "$METADATA_FILE.tmp" && \
    mv "$METADATA_FILE.tmp" "$METADATA_FILE"
fi

# Move instance directory to archive
mv "$INSTANCES_DIR/$INSTANCE_NAME" "$ARCHIVE_PATH"
echo "  ✓ Metadata archived"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ Instance '$INSTANCE_NAME' destroyed successfully"
echo ""
echo "  Hetzner server:  Deleted"
echo "  SSH keys:        Removed"
echo "  Metadata:        Archived to instances/.archive/${INSTANCE_NAME}-${TIMESTAMP}/"
echo "════════════════════════════════════════════════════════════════"
