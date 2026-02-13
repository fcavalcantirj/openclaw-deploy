#!/usr/bin/env bash
# ============================================================================
# provision.sh — Provision a Hetzner Cloud VM for OpenClaw
# ============================================================================
set -euo pipefail

# ── Parse arguments ─────────────────────────────────────────────────────────
NAME=""
REGION="nbg1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--name NAME] [--region REGION]"
      exit 1
      ;;
  esac
done

# Auto-generate name if not provided
if [ -z "$NAME" ]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  NAME="openclaw-${TIMESTAMP}"
fi

# ── Configuration ───────────────────────────────────────────────────────────
SERVER_TYPE="cx23"          # 2 vCPU, 4GB RAM, 40GB SSD — ~$3.49/mo
IMAGE="ubuntu-24.04"
SSH_KEY_NAME="openclaw-${NAME}"
SSH_KEY_PATH="$HOME/.ssh/openclaw_${NAME}"
INSTANCES_DIR="$(cd "$(dirname "$0")/.." && pwd)/instances"
INSTANCE_DIR="${INSTANCES_DIR}/${NAME}"

echo "════════════════════════════════════════════════════════════════"
echo "  Provisioning OpenClaw Instance"
echo "  Name:   $NAME"
echo "  Region: $REGION"
echo "  Type:   $SERVER_TYPE"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Generate SSH key if it doesn't exist ───────────────────────────
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "🔑 Generating SSH key at $SSH_KEY_PATH..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "openclaw-${NAME}"
  echo ""
else
  echo "✓ SSH key already exists at $SSH_KEY_PATH"
fi

# ── Step 2: Upload SSH key to Hetzner (idempotent) ─────────────────────────
if ! hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  echo "📤 Uploading SSH key to Hetzner..."
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_PATH}.pub"
  echo ""
else
  echo "✓ SSH key '$SSH_KEY_NAME' already exists in Hetzner"
  echo ""
fi

# ── Step 3: Create the server ──────────────────────────────────────────────
if hcloud server describe "$NAME" &>/dev/null; then
  echo "✓ Server '$NAME' already exists"
  SERVER_IP=$(hcloud server ip "$NAME")
else
  echo "🖥️  Creating server '$NAME' ($SERVER_TYPE in $REGION)..."
  hcloud server create \
    --name "$NAME" \
    --type "$SERVER_TYPE" \
    --image "$IMAGE" \
    --location "$REGION" \
    --ssh-key "$SSH_KEY_NAME" \
    > /dev/null

  SERVER_IP=$(hcloud server ip "$NAME")
  echo "✓ Server created with IP: $SERVER_IP"
  echo ""
  echo "⏳ Waiting 30s for server to fully boot..."
  sleep 30
  echo ""
fi

# ── Step 4: Verify SSH connectivity ────────────────────────────────────────
echo "🔐 Verifying SSH connectivity..."
MAX_RETRIES=5
RETRY_COUNT=0
SSH_OK=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$SERVER_IP" 'echo ok' &>/dev/null; then
    SSH_OK=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "  Retry $RETRY_COUNT/$MAX_RETRIES..."
  sleep 5
done

if [ "$SSH_OK" = false ]; then
  echo "❌ Failed to establish SSH connection after $MAX_RETRIES attempts"
  exit 1
fi

echo "✓ SSH connection verified"
echo ""

# ── Step 5: Create instance directory and metadata ─────────────────────────
mkdir -p "$INSTANCE_DIR"

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "${INSTANCE_DIR}/metadata.json" <<EOF
{
  "name": "$NAME",
  "ip": "$SERVER_IP",
  "region": "$REGION",
  "server_type": "$SERVER_TYPE",
  "status": "provisioned",
  "created_at": "$CREATED_AT",
  "ssh_key_path": "$SSH_KEY_PATH"
}
EOF

echo "✓ Metadata written to ${INSTANCE_DIR}/metadata.json"
echo ""

# ── Done ────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ Provisioning Complete"
echo ""
echo "  Server:  $NAME"
echo "  IP:      $SERVER_IP"
echo "  Region:  $REGION"
echo "  SSH:     ssh -i $SSH_KEY_PATH root@$SERVER_IP"
echo ""
echo "  Metadata: ${INSTANCE_DIR}/metadata.json"
echo "════════════════════════════════════════════════════════════════"
