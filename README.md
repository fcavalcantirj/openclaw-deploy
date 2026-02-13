# OpenClaw Deploy

**Automated deployment and fleet management for OpenClaw Gateway instances on Hetzner Cloud.**

Turn your parent OpenClaw into a fleet manager: deploy, monitor, control, and manage child instances—each with their own Telegram bot for end users.

---

## What This Does

OpenClaw Deploy is a complete infrastructure skill that provides:

### Core Capabilities
✅ **Automated Deployment** - Provision VMs and install OpenClaw in minutes
✅ **User Onboarding** - Complete Telegram bot setup and user pairing workflows
✅ **Fleet Management** - Control multiple instances from a single parent Claw
✅ **Monitoring** - Health checks, logs, and alerts for all instances
✅ **Recovery** - Automatic resuscitation of crashed instances
✅ **Security** - Loopback binding, UFW firewall, Tailscale VPN, token auth

### Use Cases
- **Multi-tenant bots**: Each user gets their own dedicated bot instance
- **Regional deployment**: Deploy instances closer to users
- **Development/testing**: Spin up temporary instances
- **Workload isolation**: Separate prod/staging/dev environments

---

## Quick Start

### Prerequisites

1. **Hetzner Cloud Account** - [Sign up](https://www.hetzner.com/cloud) and get API token
2. **Anthropic API Key** - Get from [console.anthropic.com](https://console.anthropic.com/)
3. **System Tools** - `hcloud` CLI, `jq`, `ssh`

### Install

```bash
# Clone repository
git clone https://github.com/yourusername/openclaw-deploy.git
cd openclaw-deploy

# Make scripts executable
chmod +x deploy.sh scripts/*.sh

# Configure hcloud
hcloud context create openclaw
hcloud context use openclaw
```

### Deploy Your First Instance

```bash
# Deploy instance (takes ~5 minutes)
./deploy.sh --name alice-bot --region nbg1

# Configure Telegram bot (get token from @BotFather)
./scripts/setup-telegram-bot.sh alice-bot 123456:ABC-DEF...

# Onboard user
./scripts/user-onboard.sh alice-bot
# User messages bot → you approve pairing → connected!

# Check status
./scripts/status.sh alice-bot
```

---

## Complete Command Reference

### 📦 Deployment Commands

| Command | Description | Example |
|---------|-------------|---------|
| `deploy.sh` | Full deployment orchestration | `./deploy.sh --name alice-bot --region nbg1` |
| `destroy.sh` | Clean teardown of instance | `./scripts/destroy.sh alice-bot --confirm` |
| `list.sh` | List all deployed instances | `./scripts/list.sh` |
| `status.sh` | Check instance health | `./scripts/status.sh alice-bot` |

**Deploy Options:**
```bash
./deploy.sh \
  --name mybot \              # Instance name (default: auto-generated)
  --region nbg1 \             # Region: nbg1, fsn1, hel1, ash
  --skip-tailscale \          # Skip Tailscale setup
  --skip-skills \             # Skip OpenAI Whisper setup
  --skip-monitoring           # Skip healthcheck timer
```

### 👤 User Management Commands

| Command | Description | Example |
|---------|-------------|---------|
| `user-onboard.sh` | Complete user onboarding | `./scripts/user-onboard.sh alice-bot BOT_TOKEN` |
| `setup-telegram-bot.sh` | Configure bot token | `./scripts/setup-telegram-bot.sh alice-bot TOKEN` |
| `approve-user.sh` | Approve pairing requests | `./scripts/approve-user.sh alice-bot --list` |
| `send-message.sh` | Send message to user | `./scripts/send-message.sh alice-bot --owner "Hello!"` |

**User Onboarding Workflow:**
```bash
# 1. Set up bot token
./scripts/setup-telegram-bot.sh alice-bot 123456:ABC-DEF...

# 2. User messages the bot on Telegram

# 3. List pending requests
./scripts/approve-user.sh alice-bot --list

# 4. Approve by pairing code
./scripts/approve-user.sh alice-bot ABC123

# Or use full orchestration
./scripts/user-onboard.sh alice-bot 123456:ABC-DEF...
```

### 💬 Messaging Commands

| Command | Description | Example |
|---------|-------------|---------|
| `send-message.sh` | Send message to user | `./scripts/send-message.sh alice-bot 12345 "Hi!"` |
| `receive-check.sh` | Check for new messages | `./scripts/receive-check.sh alice-bot --follow` |

**Send Messages:**
```bash
# Send to specific user ID
./scripts/send-message.sh alice-bot 123456789 "Welcome!"

# Send to username
./scripts/send-message.sh alice-bot @username "Message"

# Send to paired owner
./scripts/send-message.sh alice-bot --owner "Your bot is ready!"
```

**Check Messages:**
```bash
# View recent activity
./scripts/receive-check.sh alice-bot

# Follow logs in real-time
./scripts/receive-check.sh alice-bot --follow

# Show last 100 entries
./scripts/receive-check.sh alice-bot -n 100
```

### ⚙️ Control Commands

| Command | Description | Example |
|---------|-------------|---------|
| `restart.sh` | Restart gateway service | `./scripts/restart.sh alice-bot` |
| `update.sh` | Update OpenClaw version | `./scripts/update.sh alice-bot latest` |
| `logs.sh` | Fetch and display logs | `./scripts/logs.sh alice-bot --follow` |
| `config-view.sh` | View/edit configuration | `./scripts/config-view.sh alice-bot --download` |

**Restart Gateway:**
```bash
# Safe restart with verification
./scripts/restart.sh alice-bot
```

**Update OpenClaw:**
```bash
# Update to latest version
./scripts/update.sh alice-bot latest

# Update to specific version
./scripts/update.sh alice-bot 0.5.0
```

**View Logs:**
```bash
# Show last 50 lines
./scripts/logs.sh alice-bot

# Follow in real-time
./scripts/logs.sh alice-bot --follow

# Show errors only
./scripts/logs.sh alice-bot --errors

# Show logs since 10 minutes ago
./scripts/logs.sh alice-bot --since '10m'
```

**Manage Config:**
```bash
# View current config
./scripts/config-view.sh alice-bot

# Download config
./scripts/config-view.sh alice-bot --download

# Upload modified config
./scripts/config-view.sh alice-bot --upload config.json

# Edit on VM
./scripts/config-view.sh alice-bot --edit
```

### 📊 Monitoring Commands

| Command | Description | Example |
|---------|-------------|---------|
| `monitor-all.sh` | Check all instances | `./scripts/monitor-all.sh --watch 60` |
| `resuscitate.sh` | Recover crashed instance | `./scripts/resuscitate.sh alice-bot` |

**Monitor Fleet:**
```bash
# Quick health check
./scripts/monitor-all.sh

# Verbose mode with details
./scripts/monitor-all.sh --verbose

# Continuous monitoring (refresh every 60s)
./scripts/monitor-all.sh --watch 60

# JSON output for automation
./scripts/monitor-all.sh --json
```

**Recover Instance:**
```bash
# Diagnose and recover
./scripts/resuscitate.sh alice-bot

# Force immediate recovery
./scripts/resuscitate.sh alice-bot --force

# Preview actions without changes
./scripts/resuscitate.sh alice-bot --dry-run
```

---

## Common Workflows

### Deploy and Onboard New User

```bash
# 1. Deploy instance
./deploy.sh --name alice-bot --region nbg1

# 2. Get bot token from @BotFather
# Message @BotFather on Telegram:
#   /newbot → follow prompts → get token

# 3. Complete onboarding
./scripts/user-onboard.sh alice-bot 123456:ABC-DEF...
# This handles: token setup, user pairing, approval

# 4. Verify
./scripts/status.sh alice-bot
```

### Manage Fleet of Instances

```bash
# Deploy multiple instances
./deploy.sh --name alice-bot --region nbg1
./deploy.sh --name bob-bot --region fsn1
./deploy.sh --name carol-bot --region hel1

# Monitor all
./scripts/monitor-all.sh --watch 60

# Send announcements
for bot in alice-bot bob-bot carol-bot; do
  ./scripts/send-message.sh $bot --owner "System maintenance tonight"
done

# Check for issues
./scripts/monitor-all.sh --verbose | grep -i "degraded\|offline"
```

### Troubleshoot Problem Instance

```bash
# 1. Check status
./scripts/status.sh alice-bot

# 2. View error logs
./scripts/logs.sh alice-bot --errors --since '1h'

# 3. Try restart
./scripts/restart.sh alice-bot

# 4. If still failing, resuscitate
./scripts/resuscitate.sh alice-bot

# 5. Last resort: redeploy
./scripts/destroy.sh alice-bot --confirm
./deploy.sh --name alice-bot
```

### Update All Instances

```bash
# Update all to latest version
./scripts/list.sh | grep -v "^NAME" | awk '{print $1}' | while read instance; do
  echo "Updating $instance..."
  ./scripts/update.sh "$instance" latest
done

# Verify all updated successfully
./scripts/monitor-all.sh --verbose
```

---

## Architecture

### System Overview

```
┌─────────────────────────────────────────────────┐
│           Parent OpenClaw (Control Plane)       │
│  ┌──────────────────────────────────────────┐  │
│  │      openclaw-deploy skill               │  │
│  │  • deploy.sh - provision instances       │  │
│  │  • monitor-all.sh - fleet health         │  │
│  │  • send-message.sh - broadcast msgs      │  │
│  │  • resuscitate.sh - auto-recovery        │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
                    │
                    │ SSH + Hetzner API
                    │
        ┌───────────┴──────────┬────────────────┐
        ▼                      ▼                ▼
  ┌─────────┐          ┌─────────┐      ┌─────────┐
  │ Child 1 │          │ Child 2 │      │ Child 3 │
  │ @bot1   │          │ @bot2   │      │ @bot3   │
  │ nbg1    │          │ fsn1    │      │ hel1    │
  └─────────┘          └─────────┘      └─────────┘
        ▲                      ▲                ▲
        │                      │                │
   User Alice              User Bob        User Carol
```

### Instance Architecture

```
Hetzner Cloud VM (cx22: 2 vCPU, 4GB RAM)
├── Ubuntu 24.04
├── Node.js 22
├── Claude Code CLI (setup only)
├── OpenClaw Gateway
│   ├── Bind: 127.0.0.1:18789 (loopback only)
│   ├── Auth: Token-based
│   └── Channels: Telegram (pairing mode)
├── Tailscale VPN
├── OpenAI Whisper Skill (optional)
├── ClawdHub CLI (optional)
├── Healthcheck Timer (5min interval)
└── UFW Firewall (SSH only)
```

### Deployment Flow

```
1. provision.sh
   └─ Creates Hetzner VM with SSH

2. bootstrap.sh
   └─ Installs Node 22, Claude Code CLI

3. setup-openclaw.sh
   └─ Claude Code installs & configures OpenClaw

4. setup-tailscale.sh
   └─ Claude Code installs Tailscale

5. setup-skills.sh
   └─ Configures Whisper, ClawdHub

6. setup-monitoring.sh
   └─ Installs healthcheck timer

7. verify.sh
   └─ Runs 10-point checklist
```

---

## Security Model

### Network Security
- ✅ Gateway binds to `127.0.0.1` only (never public)
- ✅ UFW firewall allows SSH only
- ✅ Tailscale VPN for secure remote access
- ✅ No public HTTP/HTTPS ports

### Authentication
- ✅ Token-based auth for gateway API
- ✅ DM pairing policy for Telegram
- ✅ SSH key authentication (no passwords)

### Credential Management
- ✅ API keys passed via CLI (never hardcoded)
- ✅ Sensitive data redacted from logs
- ✅ SSH keys per-instance in `instances/` (gitignored)
- ✅ Bot tokens stored only on VMs

### Best Practices
```bash
# Store credentials securely
echo '{"anthropic_api_key": "sk-ant-..."}' > instances/credentials.json
chmod 600 instances/credentials.json

# Rotate bot tokens periodically
./scripts/setup-telegram-bot.sh alice-bot NEW_TOKEN

# Monitor for security issues
./scripts/logs.sh alice-bot --errors | grep -i "auth\|security"

# Review firewall rules
ssh -i ~/.ssh/openclaw_alice openclaw@IP "sudo ufw status"
```

---

## Monitoring & Alerts

### Health Check Categories

| Status | Description | Action |
|--------|-------------|--------|
| HEALTHY | All checks passed | Continue monitoring |
| DEGRADED | Issues detected (high errors, disk, etc.) | Investigate logs |
| OFFLINE | Gateway not running | Restart or resuscitate |
| UNREACHABLE | Cannot connect to VM | Check VM status |

### Monitoring Setup Options

**Option 1: Manual Watch**
```bash
./scripts/monitor-all.sh --watch 60
```

**Option 2: Cron Job**
```bash
# Add to crontab
*/5 * * * * /path/to/openclaw-deploy/scripts/monitor-all.sh --json > /tmp/fleet-status.json
```

**Option 3: Integrated with Parent Claw** _(Task 24 - in progress)_
```bash
# Future: Parent Claw monitors children automatically
# via cron/heartbeat integration
```

### Alert Examples

```bash
# Check for degraded instances
./scripts/monitor-all.sh --json | jq '.[] | select(.status == "DEGRADED")'

# Email on failures (add to cron)
#!/bin/bash
STATUS=$(./scripts/monitor-all.sh --json)
FAILURES=$(echo "$STATUS" | jq -r '.[] | select(.status != "HEALTHY") | .instance')
if [ -n "$FAILURES" ]; then
  echo "$FAILURES" | mail -s "OpenClaw Fleet Alert" admin@example.com
fi
```

---

## Cost Estimation

### Per Instance

| Component | Cost | Notes |
|-----------|------|-------|
| Hetzner cx22 VM | €4.35/mo | 2 vCPU, 4GB RAM, 40GB SSD |
| Anthropic API | ~$0.10 | One-time setup only |
| OpenAI Whisper | ~$0.006/min | Optional, per audio minute |
| Telegram Bot | Free | Unlimited messages |

**Total: ~$5/month per instance** (+ optional API usage)

### Fleet Examples

| Fleet Size | Monthly Cost | Use Case |
|------------|--------------|----------|
| 1 instance | $5 | Personal bot |
| 10 instances | $50 | Small team |
| 100 instances | $500 | Multi-tenant service |

---

## Troubleshooting

### Common Issues

**"hcloud: command not found"**
```bash
# Install hcloud CLI
brew install hcloud  # macOS
# Or: https://github.com/hetznercloud/cli
```

**"No active context"**
```bash
hcloud context create openclaw
# Enter your Hetzner API token
hcloud context use openclaw
```

**"Instance already exists"**
```bash
# Option 1: Use different name
./deploy.sh --name alice-bot-2

# Option 2: Destroy and redeploy
./scripts/destroy.sh alice-bot --confirm
./deploy.sh --name alice-bot
```

**"Gateway not responding"**
```bash
# Check logs
./scripts/logs.sh alice-bot --errors

# Restart
./scripts/restart.sh alice-bot

# Resuscitate if crashed
./scripts/resuscitate.sh alice-bot
```

**"SSH connection refused"**
```bash
# Check VM is running
hcloud server list

# Wait for SSH to start (30s after creation)
sleep 30 && ssh -i ~/.ssh/openclaw_alice openclaw@IP
```

### Debug Checklist

```bash
# 1. Check instance exists
./scripts/list.sh

# 2. Check VM status
hcloud server describe alice-bot

# 3. Check gateway status
./scripts/status.sh alice-bot

# 4. Check recent logs
./scripts/logs.sh alice-bot -n 50 --errors

# 5. Check disk space
ssh -i ~/.ssh/openclaw_alice openclaw@IP "df -h"

# 6. Check memory
ssh -i ~/.ssh/openclaw_alice openclaw@IP "free -h"

# 7. Try resuscitation
./scripts/resuscitate.sh alice-bot
```

---

## File Structure

```
openclaw-deploy/
├── deploy.sh                    # Master orchestrator
├── SKILL.md                     # Skill specification
├── README.md                    # This file
├── CLAUDE.md                    # Project guidelines
├── SPEC.md                      # Technical specification
│
├── scripts/
│   ├── provision.sh             # Create Hetzner VM
│   ├── bootstrap.sh             # Install Node + Claude Code
│   ├── setup-openclaw.sh        # Install OpenClaw
│   ├── setup-tailscale.sh       # Install Tailscale
│   ├── setup-skills.sh          # Configure skills
│   ├── setup-monitoring.sh      # Install healthcheck
│   ├── verify.sh                # Run verification
│   │
│   ├── setup-telegram-bot.sh    # Configure bot token
│   ├── approve-user.sh          # Approve pairing
│   ├── user-onboard.sh          # Full onboarding
│   │
│   ├── send-message.sh          # Send messages
│   ├── receive-check.sh         # Check messages
│   │
│   ├── restart.sh               # Restart gateway
│   ├── update.sh                # Update OpenClaw
│   ├── logs.sh                  # View logs
│   ├── config-view.sh           # Manage config
│   │
│   ├── monitor-all.sh           # Fleet monitoring
│   ├── resuscitate.sh           # Instance recovery
│   │
│   ├── status.sh                # Instance status
│   ├── list.sh                  # List instances
│   └── destroy.sh               # Teardown
│
├── prompts/
│   ├── setup-openclaw.md        # Claude Code prompt
│   └── setup-tailscale.md       # Claude Code prompt
│
├── templates/
│   └── openclaw.json            # Base config
│
├── instances/                   # Runtime state (gitignored)
│   └── <name>/
│       ├── metadata.json        # Instance details
│       ├── ssh_key              # SSH private key
│       └── ssh_key.pub          # SSH public key
│
└── specs/
    ├── prd-v1.json              # Task tracking
    └── progress.txt             # Progress log
```

---

## Advanced Topics

### Custom Configuration Templates

```bash
# Edit base template
vim templates/openclaw.json

# Deploy with custom config
./deploy.sh --name alice-bot
```

### Multi-Region Deployment

```bash
# Deploy across multiple regions
for region in nbg1 fsn1 hel1; do
  ./deploy.sh --name "bot-$region" --region "$region"
done

# Check latency
for region in nbg1 fsn1 hel1; do
  IP=$(jq -r '.ip' "instances/bot-$region/metadata.json")
  ping -c 3 "$IP"
done
```

### Bulk Operations

```bash
# Restart all instances
./scripts/list.sh | grep -v "^NAME" | awk '{print $1}' | while read instance; do
  ./scripts/restart.sh "$instance"
done

# Check health of all instances
./scripts/monitor-all.sh --json | jq '.[] | "\(.instance): \(.status)"'

# Backup all configs
mkdir -p backups/$(date +%Y%m%d)
./scripts/list.sh | grep -v "^NAME" | awk '{print $1}' | while read instance; do
  ./scripts/config-view.sh "$instance" --download
  cp "instances/$instance/config.json" "backups/$(date +%Y%m%d)/$instance.json"
done
```

### Integration with Parent Claw

```bash
# Add to parent Claw's scripts
cd ~/parent-claw/scripts
ln -s ~/openclaw-deploy/scripts/monitor-all.sh monitor-children.sh

# Schedule monitoring
crontab -e
# Add: */5 * * * * ~/openclaw-deploy/scripts/monitor-all.sh --quiet >> ~/fleet.log 2>&1
```

---

## Development

### Testing Scripts

Scripts are **idempotent** - safe to run multiple times:

```bash
# Test syntax
bash -n scripts/restart.sh

# Test deployment
./deploy.sh --name test-bot --skip-tailscale --skip-skills

# Test full flow
./deploy.sh --name test-full
./scripts/user-onboard.sh test-full
./scripts/monitor-all.sh
./scripts/destroy.sh test-full --confirm
```

### Adding New Features

1. Create script in `scripts/`
2. Follow patterns from existing scripts (colors, error handling, etc.)
3. Add to `specs/prd-v1.json`
4. Test thoroughly
5. Update documentation (README, SKILL.md)
6. Commit with conventional commit message

### Code Quality Checklist

- ✅ Bash syntax check: `bash -n script.sh`
- ✅ Idempotent design
- ✅ Proper error handling (`set -euo pipefail`)
- ✅ Clear status messages (colors, formatting)
- ✅ No hardcoded credentials
- ✅ Follows script patterns from CLAUDE.md

---

## Roadmap

### v1.0 (Current) ✅
- Full deployment automation
- User management & onboarding
- Fleet monitoring & control
- Instance recovery
- Comprehensive documentation

### v1.1 (In Progress)
- Task 24: Cron/heartbeat integration
- Automated alerting (email, Slack, Telegram)
- Web dashboard for fleet management
- Cost tracking and reporting

### v1.2 (Planned)
- Multi-cloud support (AWS, GCP, DigitalOcean)
- Auto-scaling based on load
- Backup and restore functionality
- Blue-green deployments
- Metrics and analytics dashboard

---

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create feature branch: `git checkout -b feature-name`
3. Make changes and test thoroughly
4. Update documentation
5. Commit with conventional commits: `git commit -m 'feat: description'`
6. Push and open Pull Request

### Commit Message Format
- `feat:` - New features
- `fix:` - Bug fixes
- `docs:` - Documentation changes
- `refactor:` - Code refactoring
- `test:` - Test additions/changes

---

## Support & Resources

### Documentation
- **Full Specification**: `SPEC.md`
- **Skill Package**: `SKILL.md`
- **Project Guidelines**: `CLAUDE.md`

### Links
- **Issues**: [GitHub Issues](https://github.com/yourusername/openclaw-deploy/issues)
- **OpenClaw Docs**: [docs.openclaw.ai](https://docs.openclaw.ai)
- **Hetzner Cloud**: [docs.hetzner.com](https://docs.hetzner.com/cloud)
- **Tailscale**: [tailscale.com/kb](https://tailscale.com/kb)

### Community
- OpenClaw Discord: [link]
- GitHub Discussions: [link]

---

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- **OpenClaw Team** - Gateway framework
- **Anthropic** - Claude Code CLI
- **Hetzner** - Cloud infrastructure
- **Tailscale** - Secure networking

---

**Built with ❤️ for the OpenClaw community**

*Manage fleets of OpenClaw instances with ease.*
