# CLAUDE.md — Project Instructions for Claude Code

## What This Is

OpenClaw Deploy Kit — Spin up fully configured OpenClaw Gateway instances on Hetzner Cloud, automated via Claude Code.

## Architecture

```
Claudius (orchestrator)          Hetzner Cloud
┌─────────────────────┐         ┌──────────────────────────────┐
│ ~/clawd/openclaw-   │  hcloud │  Ubuntu 24.04 VM             │
│    deploy/          │────────►│  ├── Node 22                 │
│                     │         │  ├── Claude Code CLI         │
│ • provisions VM     │         │  ├── OpenClaw Gateway        │
│ • uploads scripts   │         │  │   └── 127.0.0.1:18789     │
│ • triggers Claude   │         │  ├── Tailscale               │
│   Code on VM        │         │  └── Health monitoring       │
│ • monitors status   │         └──────────────────────────────┘
└─────────────────────┘
```

## Key Decisions

- **Cloud**: Hetzner (cheap, reliable) — design for provider extensibility
- **Telegram**: One bot per instance (scales better than shared bot)
- **Tailscale**: Single tailnet, use tags for organization
- **Naming**: `openclaw-{purpose}-{region}` or custom
- **Credentials**: Stored securely on filesystem + AgentMemory vault

## Directory Structure

```
openclaw-deploy/
├── CLAUDE.md              # This file
├── README.md              # User-facing docs
├── specs/                 # Task specifications (claude code spec format)
│   ├── 01-provision.json
│   ├── 02-bootstrap.json
│   └── ...
├── scripts/
│   ├── provision.sh       # Main provisioning script
│   ├── bootstrap.sh       # Runs on VM (installs Node, Claude Code)
│   └── healthcheck.sh     # Monitoring script
├── prompts/
│   └── setup-openclaw.md  # Claude Code prompt for VM setup
├── templates/
│   └── openclaw.json      # Base config template
└── instances/             # State for deployed instances
    └── {instance-name}/
        ├── metadata.json  # IP, region, created_at, status
        └── config.json    # Instance-specific config
```

## Workflow (Human + AI)

1. Human: "Spin up a new OpenClaw for research"
2. Claudius: Asks clarifying questions (name, region, bot token)
3. Claudius: Provisions VM via hcloud
4. Claudius: Runs bootstrap (Node + Claude Code)
5. Claudius: Triggers Claude Code on VM with setup prompt
6. Claudius: Waits for Tailscale auth (human clicks link)
7. Claudius: Verifies everything works
8. Claudius: Reports back with quickref

## Credentials Required

| Credential | Where Stored | Who Provides |
|------------|--------------|--------------|
| Hetzner API token | `~/.config/hcloud/cli.toml` | Human (one-time) |
| Anthropic API key | AgentMemory vault | Human (one-time) |
| Telegram bot token | Asked during spinup | Human (per instance) |
| Tailscale auth | Human clicks link | Human (per instance) |

## Commands

```bash
# Provision new instance
./scripts/provision.sh --name openclaw-research --region nbg1

# Check instance status
./scripts/status.sh openclaw-research

# List all instances
./scripts/list.sh

# Destroy instance
./scripts/destroy.sh openclaw-research
```

## Specs

Task specs live in `specs/` directory. Format:

```json
{
  "category": "provision",
  "description": "What this task accomplishes",
  "steps": [
    "Step 1: Do X",
    "Step 2: Verify Y",
    "Step 3: Handle error Z"
  ],
  "passes": false
}
```

Run specs: `claude spec run specs/01-provision.json`
