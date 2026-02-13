# OpenClaw Deploy — Full Specification

## Overview

Autonomous provisioning and configuration of OpenClaw Gateway instances on Hetzner Cloud.

## Architecture

```
Orchestrator (this repo)          Hetzner Cloud VMs
┌─────────────────────────┐      ┌──────────────────────────────┐
│ scripts/                │      │  Ubuntu 24.04                │
│   provision.sh          │─────►│  ├── Node 22                 │
│   bootstrap.sh          │      │  ├── Claude Code CLI         │
│   deploy.sh (master)    │      │  ├── OpenClaw Gateway        │
│                         │      │  │   └── 127.0.0.1:18789     │
│ prompts/                │      │  ├── Tailscale               │
│   setup-openclaw.md     │      │  └── Healthcheck timer       │
└─────────────────────────┘      └──────────────────────────────┘
```

## Components

### 1. Infrastructure Setup

**hcloud CLI Configuration:**
- Context: `openclaw`
- Config: `~/.config/hcloud/cli.toml`
- Verify: `hcloud server list`

**SSH Keys:**
- Format: ed25519
- Location: `~/.ssh/openclaw_{name}`
- Upload to Hetzner: `hcloud ssh-key create`

### 2. VM Provisioning

**Server Specs:**
- Type: cx22 (2 vCPU, 4GB RAM, €4/mo)
- Image: ubuntu-24.04
- Regions: nbg1 (default), fsn1, hel1, ash

**Provisioning Steps:**
1. Generate SSH key if not exists
2. Upload SSH key to Hetzner
3. Create server: `hcloud server create --name {name} --type cx22 --image ubuntu-24.04`
4. Wait for boot (30s)
5. Verify SSH connectivity
6. Write metadata to `instances/{name}/metadata.json`

### 3. VM Bootstrap

**Installed on VM:**
- System: curl, git, jq, ufw, tmux
- Node.js 22 via nodesource
- Claude Code CLI: `npm i -g @anthropic-ai/claude-code`
- UFW firewall: allow SSH only

**User Setup:**
- Create `openclaw` user with sudo
- Copy setup prompt to `/home/openclaw/`

### 4. OpenClaw Installation (via Claude Code)

**Claude Code runs on VM with prompt from `prompts/setup-openclaw.md`:**

Phase 1: Install OpenClaw
```bash
npm install -g openclaw@latest
openclaw gateway install
loginctl enable-linger openclaw
```

Phase 2: Configure Gateway
```json5
{
  gateway: { bind: "loopback", port: 18789, auth: { mode: "token" } },
  channels: { telegram: { enabled: true, dmPolicy: "pairing" } },
  logging: { redactSensitive: true }
}
```

Phase 3: Install Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

Phase 4: Setup Monitoring
- Healthcheck script: `~/scripts/healthcheck.sh`
- Systemd timer: 5 minute interval
- Log rotation

Phase 5: Verification
- All 10 checks must pass
- Generate QUICKREF.md

### 5. Telegram Configuration

**Flow:**
1. User provides bot token from BotFather
2. Validate format: `/^[0-9]+:[A-Za-z0-9_-]+$/`
3. Test via API: `curl api.telegram.org/bot{token}/getMe`
4. Update OpenClaw config
5. Restart gateway
6. User messages bot
7. Approve pairing code

### 6. Instance Management

**metadata.json:**
```json
{
  "name": "openclaw-research-nbg1",
  "ip": "1.2.3.4",
  "tailscale_ip": "100.x.x.x",
  "region": "nbg1",
  "status": "operational",
  "created_at": "2026-02-13T...",
  "openclaw_version": "0.x.x",
  "telegram_bot": "@MyBot"
}
```

**Status Values:**
- provisioned → bootstrapped → openclaw-installed → operational
- degraded (if verification fails)

### 7. Security Model

- Gateway binds to loopback only (never public)
- UFW blocks all except SSH
- Tailscale for remote access
- Token auth required
- DM pairing for Telegram
- Sensitive data redaction in logs

### 8. Credentials

| Credential | Storage | Usage |
|------------|---------|-------|
| Hetzner API | ~/.config/hcloud/cli.toml | VM provisioning |
| Anthropic | instances/credentials.json | Claude Code on VMs |
| OpenAI | ~/.openclaw/openclaw.json | Whisper skill |
| Telegram | User provides per instance | Bot communication |

### 9. Scripts Reference

| Script | Purpose | Inputs |
|--------|---------|--------|
| provision.sh | Create Hetzner VM | --name, --region |
| bootstrap.sh | Install Node + Claude Code | (runs on VM) |
| deploy.sh | Full deployment orchestration | --name, --region |
| status.sh | Check instance status | instance-name |
| list.sh | List all instances | (none) |
| destroy.sh | Remove instance | instance-name, --confirm |
| healthcheck.sh | Monitor gateway | (runs on VM) |

### 10. Testing

**Verification Checklist:**
1. SSH connectivity
2. `openclaw --version`
3. `openclaw gateway status` = running
4. `systemctl --user is-active openclaw-gateway` = active
5. `tailscale status` = connected
6. `openclaw channels status` = telegram enabled
7. Healthcheck timer active
8. UFW firewall enabled
9. Disk space > 50% free
10. Memory reasonable

All 10 must pass for status = operational.
