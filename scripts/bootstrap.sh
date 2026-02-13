#!/usr/bin/env bash
# ============================================================================
# 02-bootstrap.sh — Runs ON the Hetzner VM via SSH
# Installs: Node 22, Claude Code CLI, essential packages
# Does NOT install OpenClaw — that's Claude Code's job.
# ============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  OpenClaw VM Bootstrap — Phase 1: System + Claude Code       ║"
echo "╚════════════════════════════════════════════════════════════════╝"

# ── System updates ────────────────────────────────────────────────────────
echo ""
echo "📦 Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ── Essential tools ───────────────────────────────────────────────────────
echo "🔧 Installing essentials..."
apt-get install -y -qq \
  curl wget git jq unzip \
  build-essential \
  ca-certificates gnupg \
  ufw \
  htop tmux

# ── Node.js 22 (OpenClaw requires 22+) ───────────────────────────────────
echo "📗 Installing Node.js 22..."
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi
echo "   Node: $(node -v)"
echo "   npm:  $(npm -v)"

# ── Claude Code CLI ──────────────────────────────────────────────────────
echo "🤖 Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code

echo "   Claude Code: $(claude --version 2>/dev/null || echo 'installed')"

# ── Firewall baseline ────────────────────────────────────────────────────
echo "🔒 Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
# Don't allow 18789 externally — OpenClaw stays on loopback
# Tailscale will handle secure remote access
ufw --force enable

# ── Create a non-root user for OpenClaw ──────────────────────────────────
echo "👤 Creating 'openclaw' user..."
if ! id openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
  usermod -aG sudo openclaw
  # Allow passwordless sudo for setup phase
  echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw
fi

# Copy Claude Code prompt to openclaw user's home (if exists)
if [ -f /root/setup-openclaw.md ]; then
  cp /root/setup-openclaw.md /home/openclaw/
  chown openclaw:openclaw /home/openclaw/setup-openclaw.md
fi

# ── Write a convenience launcher script ──────────────────────────────────
cat > /home/openclaw/run-claude-setup.sh << 'LAUNCHER'
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Run this as the 'openclaw' user to kick off Claude Code setup
# Usage: ANTHROPIC_API_KEY=sk-ant-... ./run-claude-setup.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "❌ ANTHROPIC_API_KEY is not set."
  echo "   Usage: ANTHROPIC_API_KEY=sk-ant-... ./run-claude-setup.sh"
  exit 1
fi

export ANTHROPIC_API_KEY

echo "🤖 Launching Claude Code to set up OpenClaw..."
echo "   Claude Code will read the setup prompt and handle everything."
echo ""

# Run Claude Code with the setup prompt
# --print mode runs non-interactively and prints the output
claude --print "$(cat /home/openclaw/setup-openclaw.md)"
LAUNCHER

chmod +x /home/openclaw/run-claude-setup.sh
chown openclaw:openclaw /home/openclaw/run-claude-setup.sh

# ── Done ─────────────────────────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ✅ Bootstrap Phase 1 Complete                                ║"
echo "║                                                               ║"
echo "║  Installed: Node $(node -v), Claude Code, UFW                   ║"
echo "║  User: openclaw (with sudo)                                   ║"
echo "║                                                               ║"
echo "║  Next: SSH in and run Claude Code as the openclaw user:       ║"
echo "║                                                               ║"
echo "║    ssh root@<IP>                                              ║"
echo "║    su - openclaw                                              ║"
echo "║    ANTHROPIC_API_KEY=sk-ant-... ./run-claude-setup.sh         ║"
echo "║                                                               ║"
echo "║  Or interactively:                                            ║"
echo "║    ANTHROPIC_API_KEY=sk-ant-... claude                        ║"
echo "║    (then paste the prompt from setup-openclaw.md)             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
