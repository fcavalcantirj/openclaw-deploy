#!/usr/bin/env bash
# ============================================================================
# 01-provision-vm.sh — Provision a Hetzner Cloud VM for OpenClaw
# ============================================================================
# Prerequisites:
#   brew install hcloud          (macOS)
#   snap install hcloud          (Linux)
#   pip install hcloud           (or via pip)
#
# Then: hcloud context create openclaw
#   → paste your Hetzner API token (from https://console.hetzner.cloud)
# ============================================================================
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
SERVER_NAME="${SERVER_NAME:-openclaw-gw}"
SERVER_TYPE="${SERVER_TYPE:-cx22}"          # 2 vCPU, 4GB RAM, 40GB SSD — ~€4/mo
IMAGE="${IMAGE:-ubuntu-24.04}"
LOCATION="${LOCATION:-nbg1}"               # Nuremberg; alternatives: fsn1, hel1, ash
SSH_KEY_NAME="${SSH_KEY_NAME:-openclaw-key}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/openclaw_ed25519}"

# ── Step 1: Generate SSH key if it doesn't exist ──────────────────────────
if [ ! -f "$SSH_KEY_PATH" ]; then
  echo "🔑 Generating SSH key at $SSH_KEY_PATH..."
  ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "openclaw-deploy"
  echo ""
fi

# ── Step 2: Upload SSH key to Hetzner (idempotent) ────────────────────────
if ! hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  echo "📤 Uploading SSH key to Hetzner..."
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_PATH}.pub"
else
  echo "✓ SSH key '$SSH_KEY_NAME' already exists in Hetzner"
fi

# ── Step 3: Create the server ─────────────────────────────────────────────
if hcloud server describe "$SERVER_NAME" &>/dev/null; then
  echo "✓ Server '$SERVER_NAME' already exists"
  SERVER_IP=$(hcloud server ip "$SERVER_NAME")
else
  echo "🖥️  Creating server '$SERVER_NAME' ($SERVER_TYPE in $LOCATION)..."
  hcloud server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --image "$IMAGE" \
    --location "$LOCATION" \
    --ssh-key "$SSH_KEY_NAME"

  SERVER_IP=$(hcloud server ip "$SERVER_NAME")
  echo ""
  echo "⏳ Waiting 30s for server to fully boot..."
  sleep 30
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Server: $SERVER_NAME"
echo "  IP:     $SERVER_IP"
echo "  SSH:    ssh -i $SSH_KEY_PATH root@$SERVER_IP"
echo "════════════════════════════════════════════════════════════════"

# ── Step 4: Copy bootstrap script & Claude Code prompt to the server ──────
echo ""
echo "📦 Uploading bootstrap files..."
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
  "$(dirname "$0")/02-bootstrap.sh" \
  "$(dirname "$0")/03-claude-code-setup-prompt.md" \
  root@"$SERVER_IP":/root/

# ── Step 5: Run the bootstrap ─────────────────────────────────────────────
echo ""
echo "🚀 Running bootstrap on the server..."
echo "   This installs Node 22, Claude Code CLI, and then hands off to Claude Code."
echo ""
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@"$SERVER_IP" \
  "chmod +x /root/02-bootstrap.sh && /root/02-bootstrap.sh"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ Bootstrap complete!"
echo ""
echo "  Next steps:"
echo "  1. SSH in:  ssh -i $SSH_KEY_PATH root@$SERVER_IP"
echo "  2. Run Claude Code to set up OpenClaw:"
echo "     ANTHROPIC_API_KEY=sk-ant-... claude"
echo "     Then paste the prompt from 03-claude-code-setup-prompt.md"
echo ""
echo "  Or run it non-interactively:"
echo "     ANTHROPIC_API_KEY=sk-ant-... claude --print < /root/03-claude-code-setup-prompt.md"
echo "════════════════════════════════════════════════════════════════"
