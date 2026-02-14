# Deployment Guide

## Prerequisites

### 1. Hetzner Cloud Account

An active Hetzner Cloud account with an API token.

```bash
# Install hcloud CLI
brew install hcloud          # macOS
# Or download: https://github.com/hetznercloud/cli

# Create and activate context
hcloud context create openclaw
hcloud context use openclaw
# Paste your Hetzner API token when prompted

# Verify
hcloud server list
```

### 2. credentials.json

Create `SKILL_DIR/instances/credentials.json` (gitignored):

```json
{
  "anthropic_api_key": "sk-ant-...",
  "parent_telegram_bot_token": "123456:ABC...",
  "parent_telegram_chat_id": "12345678",
  "agentmail_api_key": "am_...",
  "agentmemory_api_key": "amem_...",
  "pinata_jwt": "eyJ...",
  "notify_email": "you@example.com",
  "solvr_api_key": "solvr_..."
}
```

Required fields: `anthropic_api_key`, `parent_telegram_bot_token`, `parent_telegram_chat_id`.
Others are optional but enable full functionality (AMCP checkpoints, email alerts, Solvr learning).

### 3. Telegram Bot Token

Each child instance needs its own bot token from [@BotFather](https://t.me/BotFather):
1. Message @BotFather: `/newbot`
2. Follow prompts to name the bot
3. Copy the token (format: `123456:ABC-DEF...`)

### 4. System Tools

```bash
# Required on parent machine
command -v hcloud   # Hetzner CLI
command -v jq       # JSON processing
command -v ssh      # Remote access
command -v curl     # HTTP requests
```

---

## Architecture

```
Parent Machine (Control Plane)
├── SKILL_DIR/claw              CLI dispatcher
├── SKILL_DIR/instances/        Per-child metadata + SSH keys
├── SKILL_DIR/credentials.json  Shared secrets (gitignored)
└── SKILL_DIR/templates/        Base configs
        │
        │ SSH + Hetzner API
        ▼
Child VMs (Hetzner Cloud, cx23)
├── Ubuntu 24.04
├── Node.js 22 (via nodesource)
├── OpenClaw Gateway (127.0.0.1:18789, token auth)
├── AMCP CLI + proactive-amcp skill
│   ├── Real KERI identity (~/.amcp/identity.json)
│   ├── Secrets in ~/.amcp/config.json
│   └── Watchdog systemd service
├── Tailscale VPN (optional)
├── UFW Firewall (SSH only)
└── Healthcheck timer (5min interval)
```

Each child is fully isolated: own VM, own Telegram bot, own AMCP identity, own Solvr account.

---

## Deploy Flow

### What Happens

```bash
SKILL_DIR/claw deploy --name alice-bot --bot-token "123456:ABC..."
```

1. **Provision** (~60s) — Creates Hetzner cx23 VM, generates SSH key, uploads to Hetzner, waits for boot
2. **Bootstrap** (~90s) — Installs Node 22, Claude Code CLI, system tools, UFW firewall
3. **Setup OpenClaw** (~120s) — Claude Code on-VM installs OpenClaw, configures gateway (loopback:18789, token auth, Telegram pairing)
4. **Setup Tailscale** (~30s) — Installs Tailscale VPN (skip with `--skip-tailscale`)
5. **Setup Skills** (~30s) — Configures optional skills like Whisper (skip with `--skip-skills`)
6. **Setup Monitoring** (~15s) — Installs healthcheck systemd timer (skip with `--skip-monitoring`)
7. **Install AMCP** (~30s) — Creates KERI identity, stores secrets in config, installs watchdog
8. **Register Solvr** — Creates child Solvr account with protocol-08 naming
9. **Verify** — Runs 10-point checklist, generates metadata
10. **Notify** — Sends Telegram notification to parent

Total time: ~5 minutes.

### Post-Deploy Verification

```bash
# Check instance is healthy
SKILL_DIR/claw status alice-bot

# View logs for any errors
SKILL_DIR/claw logs alice-bot

# Approve a Telegram user (after they message the bot)
SKILL_DIR/claw approve alice-bot PAIRING_CODE
```

---

## Deploy Flags Reference

| Flag | Required | Description | Default |
|------|----------|-------------|---------|
| `--name` | Yes | Instance name (alphanumeric + hyphens) | — |
| `--bot-token` | Yes | Telegram bot token from @BotFather | — |
| `--region` | No | Hetzner region | nbg1 |
| `--type` | No | Server type | cx23 |
| `--skip-tailscale` | No | Skip VPN setup | — |
| `--skip-skills` | No | Skip optional skills | — |
| `--skip-monitoring` | No | Skip healthcheck timer | — |
| `--checkpoint-interval` | No | AMCP checkpoint frequency | 1h |
| `--parent-solvr-name` | No | Override parent Solvr name | auto-detected |
| `--parent-telegram-token` | No | Override parent Telegram token | from credentials.json |
| `--parent-chat-id` | No | Override parent chat ID | from credentials.json |
| `--parent-email` | No | Override parent email | from credentials.json |

---

## Instance Metadata

Each deployed instance stores metadata at `SKILL_DIR/instances/{name}/metadata.json`:

```json
{
  "name": "alice-bot",
  "ip": "1.2.3.4",
  "region": "nbg1",
  "ssh_key_path": "/path/to/instances/alice-bot/ssh_key",
  "ssh_user": "root",
  "gateway_token": "tok_...",
  "parent_telegram_token": "123456:ABC...",
  "parent_chat_id": "12345678",
  "parent_email": "you@example.com",
  "created_at": "2026-02-14T12:00:00Z"
}
```

SSH keys are stored alongside: `SKILL_DIR/instances/{name}/ssh_key` and `ssh_key.pub`.

---

## Multi-Region Deployment

Deploy across regions for lower latency:

```bash
SKILL_DIR/claw deploy --name bot-eu --bot-token "$EU_TOKEN" --region nbg1
SKILL_DIR/claw deploy --name bot-eu2 --bot-token "$EU2_TOKEN" --region fsn1
SKILL_DIR/claw deploy --name bot-fi --bot-token "$FI_TOKEN" --region hel1
```

Available regions: `nbg1` (Nuremberg), `fsn1` (Falkenstein), `hel1` (Helsinki), `ash` (Ashburn, US).

---

## Cost

| Component | Cost | Notes |
|-----------|------|-------|
| Hetzner cx23 VM | ~$5/mo | 2 vCPU, 4GB RAM, 40GB SSD |
| Telegram Bot API | Free | Unlimited messages |
| Anthropic API | ~$0.10 | One-time setup (Claude Code on-VM) |
| Bandwidth | Included | 20TB/mo with Hetzner |
