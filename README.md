# OpenClaw Deploy

Automated deployment of OpenClaw Gateway instances on Hetzner Cloud VMs.

## What This Does

This project provides scripts that:
1. Provision Ubuntu 24.04 VMs on Hetzner Cloud
2. Install Node.js 22 and Claude Code CLI
3. Use Claude Code on the VM to install and configure OpenClaw Gateway
4. Set up Tailscale for secure remote access
5. Configure OpenAI Whisper and ClawdHub CLI
6. Install health monitoring
7. Provide full management tools (status, list, destroy)

## Prerequisites

### Required

1. **Hetzner Cloud Account**
   - Sign up at https://www.hetzner.com/cloud
   - Create API token: Console → Security → API Tokens
   - Configure hcloud CLI:
     ```bash
     hcloud context create openclaw
     # Paste your API token when prompted
     ```

2. **Anthropic API Key**
   - Get key from https://console.anthropic.com/
   - Used for Claude Code on VMs during setup
   - Keep it secure - passed via CLI argument

3. **System Tools**
   - `hcloud` CLI: https://github.com/hetznercloud/cli
   - `jq` for JSON parsing: `sudo apt install jq`
   - `ssh` and `ssh-keygen` (usually pre-installed)

### Optional

- **OpenAI API Key**: For Whisper speech-to-text skill
- **Telegram Bot Token**: From @BotFather for bot integration

## Quick Start

### 1. Clone and Configure

```bash
git clone https://github.com/yourusername/openclaw-deploy.git
cd openclaw-deploy
chmod +x deploy.sh scripts/*.sh
```

### 2. Deploy an Instance

```bash
./deploy.sh \
  --name mybot \
  --region nbg1 \
  --anthropic-key YOUR_ANTHROPIC_KEY \
  --openai-key YOUR_OPENAI_KEY
```

The script will:
- Create a Hetzner VM (cx22: 2 vCPU, 4GB RAM)
- Install all dependencies
- Configure OpenClaw Gateway
- Install Tailscale (you'll need to click auth URL)
- Set up monitoring
- Run verification checks

### 3. Connect Your Telegram Bot

After deployment, configure your Telegram bot:

```bash
# SSH to your instance
ssh -i ~/.ssh/openclaw_mybot openclaw@<SERVER_IP>

# Configure bot token (get from @BotFather)
openclaw channels telegram setup

# Follow prompts to enter token
# Message your bot and approve pairing code
```

### 4. Check Status

```bash
# List all instances
./scripts/list.sh

# Check specific instance
./scripts/status.sh mybot
```

## Command Reference

### Deployment

```bash
# Full deployment with all features
./deploy.sh --name mybot --region nbg1 --anthropic-key KEY --openai-key KEY

# Minimal deployment (no Tailscale, no skills)
./deploy.sh --name mybot --anthropic-key KEY --skip-tailscale --skip-skills

# Auto-generated name
./deploy.sh --anthropic-key KEY
```

**Flags:**
- `--name` - Instance name (default: openclaw-REGION-RANDOM)
- `--region` - Hetzner region: nbg1 (default), fsn1, hel1, ash
- `--anthropic-key` - Anthropic API key (required)
- `--openai-key` - OpenAI API key (optional)
- `--skip-tailscale` - Skip Tailscale setup
- `--skip-skills` - Skip skills configuration
- `--skip-monitoring` - Skip healthcheck setup

### Instance Management

```bash
# List all instances
./scripts/list.sh

# Check instance status (with live checks)
./scripts/status.sh mybot

# Destroy instance
./scripts/destroy.sh mybot --confirm
```

### Manual Step-by-Step

If you want to run steps individually:

```bash
# 1. Provision VM
./scripts/provision.sh --name mybot --region nbg1

# 2. Bootstrap (install Node + Claude Code)
./scripts/bootstrap.sh mybot

# 3. Setup OpenClaw
./scripts/setup-openclaw.sh mybot YOUR_ANTHROPIC_KEY

# 4. Setup Tailscale
./scripts/setup-tailscale.sh mybot YOUR_ANTHROPIC_KEY

# 5. Setup Skills (optional)
./scripts/setup-skills.sh mybot YOUR_OPENAI_KEY

# 6. Setup Monitoring
./scripts/setup-monitoring.sh mybot

# 7. Verify installation
./scripts/verify.sh mybot
```

## Architecture

```
┌─────────────────────────┐      ┌──────────────────────────────┐
│ Orchestrator (local)    │      │  Hetzner Cloud VM            │
│                         │      │                              │
│ • provision.sh          │─────▶│  Ubuntu 24.04                │
│ • bootstrap.sh          │      │  ├── Node 22                 │
│ • deploy.sh             │      │  ├── Claude Code CLI         │
│                         │      │  ├── OpenClaw Gateway        │
│ prompts/                │      │  │   └── 127.0.0.1:18789     │
│ • setup-openclaw.md     │──────┤  ├── Tailscale               │
│ • setup-tailscale.md    │      │  ├── OpenAI Whisper (opt)    │
│                         │      │  └── Healthcheck timer       │
└─────────────────────────┘      └──────────────────────────────┘
```

### How It Works

1. **Local scripts** provision VM and install basic tools
2. **Claude Code runs ON the VM** to handle complex configuration
3. **Gateway binds to loopback** (127.0.0.1) - not exposed to internet
4. **Tailscale provides secure access** - no public ports except SSH
5. **Healthcheck timer** monitors gateway every 5 minutes

## Security Model

### Network Security
- Gateway binds to `127.0.0.1` only (never exposed to public)
- UFW firewall allows SSH only
- Tailscale for secure remote access
- No public HTTP/HTTPS ports

### Authentication
- Token-based auth for gateway API
- Pairing policy for Telegram DMs
- SSH key authentication (no passwords)

### Credential Management
- API keys passed via CLI (never hardcoded)
- Sensitive data redacted from logs
- Credentials stored in VM config files only
- SSH keys stored in `instances/<name>/` (gitignored)

### Best Practices
- Keep Anthropic/OpenAI keys secure
- Rotate bot tokens periodically
- Monitor instance status regularly
- Review logs for unusual activity

## Cost Breakdown

### Hetzner Cloud (per instance)
- **cx22**: €4.59/month (~$5/month)
  - 2 vCPU (AMD)
  - 4GB RAM
  - 40GB SSD
  - 20TB traffic

### API Usage (estimated)
- **Anthropic**: One-time setup only (~$0.10)
- **OpenAI Whisper**: Per audio minute (~$0.006/min)
- **Telegram**: Free

**Total: ~$5/month** per instance + API usage

## Troubleshooting

### Deployment Issues

**"hcloud: command not found"**
```bash
# Install hcloud CLI
brew install hcloud  # macOS
# Or follow: https://github.com/hetznercloud/cli
```

**"No active context"**
```bash
hcloud context create openclaw
# Enter your Hetzner API token
```

**SSH connection refused**
```bash
# Check VM is running
hcloud server list

# Check firewall allows your IP
hcloud server describe <name>

# Wait 30s after creation for SSH to start
```

### Runtime Issues

**Gateway not running**
```bash
ssh -i ~/.ssh/openclaw_<name> openclaw@<IP>

# Check status
openclaw gateway status

# Check logs
journalctl --user -u openclaw-gateway -n 50

# Restart
openclaw gateway restart
```

**Tailscale not connected**
```bash
sudo tailscale status

# Reconnect
sudo tailscale up
```

**High memory usage**
```bash
# Check processes
top

# Restart gateway to free memory
openclaw gateway restart
```

### Common Errors

**"ANTHROPIC_API_KEY invalid"**
- Verify key at https://console.anthropic.com/
- Ensure key starts with `sk-ant-`
- Check for trailing spaces

**"Instance already exists"**
- Choose different name
- Or destroy existing: `./scripts/destroy.sh <name> --confirm`

**"SSH key not found"**
- Check `instances/<name>/metadata.json` for correct path
- Regenerate: `./scripts/provision.sh --name <name>`

## File Structure

```
openclaw-deploy/
├── deploy.sh              # Master orchestrator
├── scripts/
│   ├── provision.sh       # Create Hetzner VM
│   ├── bootstrap.sh       # Install Node + Claude Code
│   ├── setup-openclaw.sh  # Claude Code installs OpenClaw
│   ├── setup-tailscale.sh # Claude Code installs Tailscale
│   ├── setup-skills.sh    # Configure whisper, clawhub
│   ├── setup-monitoring.sh# Healthcheck timer
│   ├── verify.sh          # Run all checks
│   ├── status.sh          # Check instance status
│   ├── list.sh            # List all instances
│   └── destroy.sh         # Clean teardown
├── prompts/
│   ├── setup-openclaw.md  # Claude Code prompt for OpenClaw
│   └── setup-tailscale.md # Claude Code prompt for Tailscale
├── templates/
│   └── openclaw.json      # Base gateway config
├── instances/             # Runtime state (gitignored)
│   └── <name>/
│       └── metadata.json  # Instance details
└── specs/
    ├── CLAUDE.md          # Project guidelines
    ├── SPEC.md            # Full specification
    └── prd-v1.json        # Task tracking
```

## Advanced Usage

### Custom Configuration

Edit `templates/openclaw.json` before deploying:
```bash
# Modify template
vim templates/openclaw.json

# Deploy with custom config
./deploy.sh --name mybot --anthropic-key KEY
```

### Multiple Regions

Deploy across regions for redundancy:
```bash
./deploy.sh --name bot-nbg --region nbg1 --anthropic-key KEY
./deploy.sh --name bot-fsn --region fsn1 --anthropic-key KEY
./deploy.sh --name bot-ash --region ash --anthropic-key KEY
```

### Bulk Operations

```bash
# List all instances
for instance in instances/*/; do
  name=$(basename "$instance")
  ./scripts/status.sh "$name"
done

# Destroy all instances
./scripts/list.sh | grep -v "^NAME" | awk '{print $1}' | while read name; do
  ./scripts/destroy.sh "$name" --confirm
done
```

## Development

### Testing Changes

Scripts are designed to be **idempotent** - safe to run multiple times.

```bash
# Test provision
./scripts/provision.sh --name test-instance --region nbg1

# Test full deployment
./deploy.sh --name test-full --anthropic-key KEY

# Clean up
./scripts/destroy.sh test-instance --confirm
./scripts/destroy.sh test-full --confirm
```

### Adding Features

1. Create script in `scripts/`
2. Add to `deploy.sh` orchestration
3. Update `specs/prd-v1.json`
4. Test thoroughly
5. Update documentation

## Contributing

1. Fork the repository
2. Create feature branch: `git checkout -b feature-name`
3. Make changes and test
4. Update documentation
5. Commit: `git commit -m 'feat: description'`
6. Push: `git push origin feature-name`
7. Open Pull Request

## License

MIT License - see LICENSE file for details

## Support

- **Issues**: https://github.com/yourusername/openclaw-deploy/issues
- **OpenClaw Docs**: https://docs.openclaw.ai
- **Hetzner Support**: https://docs.hetzner.com/cloud

## Acknowledgments

- **OpenClaw**: Gateway framework
- **Anthropic**: Claude Code CLI
- **Hetzner**: Cloud infrastructure
- **Tailscale**: Secure networking
