# OpenClaw Deploy — Skill Specification

## Overview

OpenClaw Deploy is a **skill** for managing fleets of child OpenClaw Gateway instances on Hetzner Cloud. This skill enables a parent OpenClaw instance to spawn, control, monitor, and manage multiple child instances—each with their own Telegram bot for end-user interaction.

## Skill Metadata

```yaml
name: openclaw-deploy
version: 1.0.0
type: infrastructure-management
category: deployment
author: OpenClaw Team
requires:
  - hcloud CLI (configured with API token)
  - ssh client
  - jq
  - bash 4.0+
platforms:
  - linux
  - macos
```

## Use Cases

### Primary Use Case: Multi-User Bot Management

A parent OpenClaw instance manages a fleet of child instances, where:
- Each child has its own dedicated Telegram bot
- End users interact with their assigned child bot
- Parent Claw can provision, monitor, control, and recover children
- Ideal for: multi-tenant setups, user isolation, scalability

### Secondary Use Cases

1. **Development/Testing**: Spin up temporary OpenClaw instances for testing
2. **Regional Deployment**: Deploy instances in different regions for lower latency
3. **Workload Isolation**: Separate production/staging/dev environments
4. **Disaster Recovery**: Quickly provision replacement instances

## Skill Architecture

```
┌─────────────────────────────────────────────────┐
│           Parent OpenClaw (You)                 │
│  ┌──────────────────────────────────────────┐  │
│  │      openclaw-deploy skill               │  │
│  │  • deploy.sh                             │  │
│  │  • monitor-all.sh                        │  │
│  │  • send-message.sh                       │  │
│  │  • resuscitate.sh                        │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
                    │
                    │ manages (via SSH + Hetzner API)
                    │
        ┌───────────┴──────────┬────────────────┐
        ▼                      ▼                ▼
  ┌─────────┐          ┌─────────┐      ┌─────────┐
  │ Child 1 │          │ Child 2 │      │ Child 3 │
  │ @bot1   │          │ @bot2   │      │ @bot3   │
  └─────────┘          └─────────┘      └─────────┘
        ▲                      ▲                ▲
        │                      │                │
   User Alice              User Bob        User Carol
```

## Skill Commands

### Deployment Commands

| Command | Description | Example |
|---------|-------------|---------|
| `deploy.sh` | Deploy a new child instance | `./deploy.sh --name alice-bot --region nbg1` |
| `destroy.sh` | Cleanly tear down an instance | `./destroy.sh alice-bot --confirm` |
| `list.sh` | List all deployed instances | `./scripts/list.sh` |
| `status.sh` | Check instance status | `./scripts/status.sh alice-bot` |

### User Management Commands

| Command | Description | Example |
|---------|-------------|---------|
| `user-onboard.sh` | Complete user onboarding flow | `./scripts/user-onboard.sh alice-bot BOT_TOKEN` |
| `setup-telegram-bot.sh` | Configure Telegram bot | `./scripts/setup-telegram-bot.sh alice-bot BOT_TOKEN` |
| `approve-user.sh` | Approve pairing requests | `./scripts/approve-user.sh alice-bot --list` |
| `send-message.sh` | Send message to user | `./scripts/send-message.sh alice-bot --owner "Hello!"` |

### Control Commands

| Command | Description | Example |
|---------|-------------|---------|
| `restart.sh` | Restart gateway service | `./scripts/restart.sh alice-bot` |
| `update.sh` | Update OpenClaw version | `./scripts/update.sh alice-bot latest` |
| `logs.sh` | Fetch and display logs | `./scripts/logs.sh alice-bot --follow` |
| `config-view.sh` | View/edit configuration | `./scripts/config-view.sh alice-bot --download` |

### Monitoring Commands

| Command | Description | Example |
|---------|-------------|---------|
| `monitor-all.sh` | Check all instances | `./scripts/monitor-all.sh --verbose` |
| `receive-check.sh` | Check for messages/events | `./scripts/receive-check.sh alice-bot -n 50` |
| `resuscitate.sh` | Recover crashed instance | `./scripts/resuscitate.sh alice-bot` |

## Installation

### Prerequisites

1. **Hetzner Cloud Account**
   ```bash
   # Install hcloud CLI
   brew install hcloud  # macOS
   # or download from https://github.com/hetznercloud/cli

   # Configure context
   hcloud context create openclaw
   hcloud context use openclaw
   ```

2. **Required Tools**
   ```bash
   # Verify dependencies
   command -v ssh
   command -v jq
   command -v git
   ```

3. **Anthropic API Key**
   - Store in `instances/credentials.json`:
     ```json
     {"anthropic_api_key": "sk-ant-..."}
     ```

### Install the Skill

```bash
# Clone the repository
git clone https://github.com/yourusername/openclaw-deploy.git
cd openclaw-deploy

# Make scripts executable
chmod +x deploy.sh scripts/*.sh

# Verify installation
./scripts/list.sh
```

## Quick Start

### Deploy Your First Child Instance

```bash
# 1. Deploy instance (takes ~5 minutes)
./deploy.sh --name alice-bot --region nbg1

# 2. Configure Telegram bot
# Get bot token from @BotFather on Telegram
./scripts/setup-telegram-bot.sh alice-bot 123456:ABC-DEF...

# 3. Onboard user
./scripts/user-onboard.sh alice-bot
# User messages bot → you approve pairing → user is connected

# 4. Monitor instance
./scripts/status.sh alice-bot
```

### Full Workflow Example

```bash
# Deploy 3 instances for 3 users
./deploy.sh --name alice-bot --region nbg1
./deploy.sh --name bob-bot --region fsn1
./deploy.sh --name carol-bot --region hel1

# Set up Telegram bots
./scripts/setup-telegram-bot.sh alice-bot $ALICE_BOT_TOKEN
./scripts/setup-telegram-bot.sh bob-bot $BOB_BOT_TOKEN
./scripts/setup-telegram-bot.sh carol-bot $CAROL_BOT_TOKEN

# Monitor all instances
./scripts/monitor-all.sh --watch 60

# Send announcement to all users
./scripts/send-message.sh alice-bot --owner "Welcome Alice!"
./scripts/send-message.sh bob-bot --owner "Welcome Bob!"
./scripts/send-message.sh carol-bot --owner "Welcome Carol!"

# Check logs for issues
./scripts/logs.sh alice-bot --errors
```

## Skill Integration with Parent OpenClaw

### Option 1: Manual Skill Invocation

Call scripts directly from your parent OpenClaw instance:

```bash
# In parent Claw's working directory
cd /path/to/openclaw-deploy
./scripts/monitor-all.sh --json | jq .
```

### Option 2: Scheduled Monitoring

Add to parent Claw's crontab:

```bash
# Monitor every 5 minutes
*/5 * * * * /path/to/openclaw-deploy/scripts/monitor-all.sh --quiet >> /var/log/openclaw-fleet.log 2>&1
```

### Option 3: Programmatic API (Future)

```javascript
// Future: OpenClaw skill API
const fleet = require('openclaw-deploy-skill');

await fleet.deploy({ name: 'alice-bot', region: 'nbg1' });
await fleet.monitor.all();
await fleet.message.send('alice-bot', 'owner', 'Hello!');
```

## Configuration

### Global Configuration

Create `instances/config.yaml`:

```yaml
defaults:
  region: nbg1
  server_type: cx22
  image: ubuntu-24.04

credentials:
  hetzner_context: openclaw
  anthropic_key_file: instances/credentials.json

monitoring:
  check_interval: 300  # 5 minutes
  alert_on_degraded: true
  alert_on_offline: true
```

### Per-Instance Configuration

Each instance stores metadata in `instances/{name}/metadata.json`:

```json
{
  "name": "alice-bot",
  "ip": "1.2.3.4",
  "region": "nbg1",
  "created_at": "2026-02-13T12:00:00Z",
  "openclaw_version": "0.5.0",
  "telegram_bot": "@AliceBot",
  "status": "operational"
}
```

## Security Model

### VM Security
- OpenClaw Gateway binds to **loopback only** (127.0.0.1)
- UFW firewall blocks all ports except SSH
- Tailscale VPN for secure remote access
- Token-based authentication required

### Credential Management
- Hetzner API token: stored in `~/.config/hcloud/cli.toml`
- Anthropic API key: stored in `instances/credentials.json` (gitignored)
- Telegram bot tokens: user-provided per instance
- SSH keys: generated per instance, stored in `instances/{name}/ssh_key`

### Access Control
- DM pairing required before users can message bots
- Parent Claw has full control via SSH
- Each child instance is isolated from others

## Monitoring & Alerting

### Health Checks

The `monitor-all.sh` script performs:
1. SSH connectivity test
2. Gateway service status
3. OpenClaw CLI responsiveness
4. Recent error log analysis
5. Disk space check
6. Memory usage check

### Status Levels

- **HEALTHY**: All checks passed
- **DEGRADED**: Gateway running but has issues (high errors, disk space, etc.)
- **OFFLINE**: Gateway not running
- **UNREACHABLE**: Cannot connect to VM

### Recommended Monitoring Setup

```bash
# Option 1: Watch mode (manual)
./scripts/monitor-all.sh --watch 60

# Option 2: Cron job (automated)
*/5 * * * * /path/to/openclaw-deploy/scripts/monitor-all.sh --json > /tmp/fleet-status.json

# Option 3: Integration with parent Claw (future)
# See Task 24: cron/heartbeat integration
```

## Troubleshooting

### Instance Won't Start

```bash
# 1. Check status
./scripts/status.sh instance-name

# 2. View recent logs
./scripts/logs.sh instance-name --errors

# 3. Try resuscitation
./scripts/resuscitate.sh instance-name

# 4. Last resort: redeploy
./scripts/destroy.sh instance-name --confirm
./deploy.sh --name instance-name
```

### High Error Rate

```bash
# Check error logs
./scripts/logs.sh instance-name --since '1h' --errors

# Restart to clear stuck states
./scripts/restart.sh instance-name

# Update to latest version
./scripts/update.sh instance-name latest
```

### Disk Space Issues

```bash
# SSH to instance and clean logs
ssh -i instances/instance-name/ssh_key openclaw@IP
journalctl --vacuum-time=7d
```

### Configuration Problems

```bash
# Download and review config
./scripts/config-view.sh instance-name --download

# Edit and upload fixed config
vim instances/instance-name/config.json
./scripts/config-view.sh instance-name --upload instances/instance-name/config.json
```

## Roadmap

### v1.0 (Current)
- ✅ Full deployment automation
- ✅ Telegram bot management
- ✅ User onboarding workflows
- ✅ Fleet monitoring
- ✅ Instance recovery

### v1.1 (Planned)
- ⏳ Cron/heartbeat integration (Task 24)
- ⏳ Automated alerting (Slack, email, Telegram)
- ⏳ Web dashboard for fleet management
- ⏳ Cost tracking and reporting

### v1.2 (Future)
- 📋 Multi-cloud support (AWS, GCP, DigitalOcean)
- 📋 Auto-scaling based on load
- 📋 Backup and restore functionality
- 📋 Blue-green deployments

## Cost Estimation

### Per Instance (Hetzner cx22)
- VM: €4.35/month
- Bandwidth: Included (20TB)
- Backups: Optional (+20%)

### 10 Instances
- Monthly: ~€44
- Yearly: ~€520

### 100 Instances
- Monthly: ~€435
- Yearly: ~€5,200

## Support & Contributing

### Documentation
- Full spec: `SPEC.md`
- Guidelines: `CLAUDE.md`
- Examples: `README.md`

### Issues & PRs
- GitHub: https://github.com/yourusername/openclaw-deploy
- Report bugs, request features, or submit improvements

### Community
- OpenClaw Discord: [link]
- Discussions: GitHub Discussions

## License

MIT License - see `LICENSE` file for details.

---

**Built with ❤️ for the OpenClaw community**
