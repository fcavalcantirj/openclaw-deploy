# OpenClaw Deploy Kit

> Spin up a Hetzner VM, install Claude Code, let Claude Code handle everything.

## Architecture

```
Your Laptop                    Hetzner VM (cx22 — €4/mo)
┌─────────────┐               ┌──────────────────────────────────┐
│             │  SSH / hcloud  │  Ubuntu 24.04                    │
│  01-provision─────────────►  │  ├── Node 22                    │
│  -vm.sh     │               │  ├── Claude Code CLI              │
│             │               │  ├── OpenClaw Gateway (loopback)  │
│             │  Tailscale     │  │   └── port 18789              │
│  Browser  ◄─────tailnet────►│  ├── Tailscale                   │
│  (Control UI)               │  ├── systemd services            │
│             │               │  └── Health monitoring            │
│  Telegram ◄────internet────►│      └── every 5 min             │
│             │               └──────────────────────────────────┘
└─────────────┘
```

## Prerequisites

| What | How |
|------|-----|
| Hetzner account | [console.hetzner.cloud](https://console.hetzner.cloud) → create API token |
| hcloud CLI | `brew install hcloud` (macOS) or `snap install hcloud` (Linux) |
| Anthropic API key | For Claude Code on the VM |
| Telegram bot token | From [@BotFather](https://t.me/BotFather) (can do after deploy) |
| Tailscale account | [tailscale.com](https://tailscale.com) (free for personal use) |

## Quick Start

### 1. Configure hcloud

```bash
hcloud context create openclaw
# Paste your Hetzner API token when prompted
```

### 2. Run the provisioner

```bash
chmod +x 01-provision-vm.sh
./01-provision-vm.sh
```

This will:
- Generate an SSH key (if needed)
- Create a cx22 server in Nuremberg
- Upload the bootstrap script
- Install Node 22 + Claude Code on the VM

### 3. SSH in and launch Claude Code

```bash
# SSH into the server
ssh -i ~/.ssh/openclaw_ed25519 root@<SERVER_IP>

# Switch to the openclaw user
su - openclaw

# Option A: Non-interactive (Claude Code reads the prompt and executes)
ANTHROPIC_API_KEY=sk-ant-your-key-here claude --print "$(cat ~/03-claude-code-setup-prompt.md)"

# Option B: Interactive (you watch Claude Code work, can intervene)
ANTHROPIC_API_KEY=sk-ant-your-key-here claude
# Then paste the contents of 03-claude-code-setup-prompt.md
```

### 4. After Claude Code finishes

Claude Code will have set up:
- ✅ OpenClaw Gateway (running as systemd user service)
- ✅ Config with loopback bind + token auth
- ✅ Telegram channel (enabled, pairing mode)
- ✅ Tailscale (installed, needs your auth)
- ✅ Health check timer (every 5 min)
- ✅ Log rotation

**You still need to:**

1. **Authenticate Tailscale** — visit the URL printed during setup
2. **Add your Telegram bot token:**
   ```bash
   # Edit the config
   nano ~/.openclaw/openclaw.json
   # Set channels.telegram.botToken to your token from BotFather
   # Then restart:
   openclaw gateway restart
   ```
3. **Message your bot** on Telegram → approve the pairing code:
   ```bash
   openclaw pairing list telegram
   openclaw pairing approve telegram <CODE>
   ```

## Files in This Kit

| File | Runs on | Purpose |
|------|---------|---------|
| `01-provision-vm.sh` | Your laptop | Creates Hetzner VM, uploads files, runs bootstrap |
| `02-bootstrap.sh` | VM (as root) | Installs Node 22, Claude Code, UFW, creates openclaw user |
| `03-claude-code-setup-prompt.md` | VM (via Claude Code) | Full instructions for Claude Code to set up OpenClaw |

## Customization

### Different server size

```bash
SERVER_TYPE=cx32 ./01-provision-vm.sh    # 4 vCPU, 8GB RAM — ~€8/mo
```

### Different region

```bash
LOCATION=ash ./01-provision-vm.sh        # Ashburn, VA (US East)
LOCATION=hel1 ./01-provision-vm.sh       # Helsinki
```

### Skip auto-bootstrap

If you want to run bootstrap manually:

```bash
# Just create the server, don't run bootstrap
hcloud server create --name openclaw-gw --type cx22 --image ubuntu-24.04 --ssh-key openclaw-key
```

## Security Model

- **OpenClaw Gateway** binds to `127.0.0.1` only — never exposed to the internet
- **UFW firewall** blocks everything except SSH
- **Tailscale** provides encrypted remote access (no port forwarding needed)
- **Token auth** required for all Gateway connections
- **DM pairing** means strangers can't drive your Telegram bot
- **Sensitive data redaction** enabled in logs

## Costs

| Service | Cost |
|---------|------|
| Hetzner cx22 | ~€4.35/mo |
| Tailscale | Free (personal) |
| Anthropic API (Claude Code setup) | ~$0.50-2.00 one-time |
| Telegram bot | Free |
| **Total monthly** | **~€4.35/mo** |

## Teardown

```bash
hcloud server delete openclaw-gw
hcloud ssh-key delete openclaw-key
```
