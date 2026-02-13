# OpenClaw Deploy — Project Guidelines

## What We're Building

Scripts that automate deploying OpenClaw Gateway on Hetzner VMs. The scripts use Claude Code CLI **on the target VM** to handle complex configuration.

## The Flow

```
Human runs: ./deploy.sh --name mybot --region nbg1

  ↓ provision.sh
Creates Hetzner VM, sets up SSH

  ↓ bootstrap.sh (via SSH)
Installs Node 22, Claude Code CLI, essentials

  ↓ setup-openclaw.sh (via SSH)
Runs Claude Code ON VM → installs & configures OpenClaw

  ↓ setup-tailscale.sh (via SSH)
Runs Claude Code ON VM → installs Tailscale, outputs auth URL
[Human clicks auth URL]

  ↓ setup-skills.sh (via SSH)
Configures whisper, clawhub

  ↓ setup-monitoring.sh (via SSH)
Installs healthcheck timer

  ↓ verify.sh (via SSH)
Runs all checks, outputs summary
```

## Golden Rules

### 1. Write Scripts, Don't Deploy

Ralph's job is to **write the deployment scripts**. Not to actually spin up VMs and test them.

- ✅ Write `provision.sh` that creates VMs
- ❌ Actually create VMs to test

### 2. Claude Code ON the VM Does the Heavy Lifting

The scripts SSH to the VM and run Claude Code there. Claude Code handles:
- Installing OpenClaw
- Configuring the gateway
- Setting up systemd services
- Installing Tailscale

### 3. Scripts Must Be Idempotent

Running a script twice should be safe. Check if things exist before creating.

### 4. Pass Credentials Securely

- Anthropic key: passed as argument or env var, set on VM
- OpenAI key: passed to setup-skills.sh
- Never hardcode keys in scripts

### 5. Handle Failures Gracefully

Scripts should:
- Check command exit codes
- Output clear error messages
- Exit with non-zero on failure

---

## File Structure

```
openclaw-deploy/
├── deploy.sh              # Master orchestrator
├── scripts/
│   ├── provision.sh       # Create Hetzner VM
│   ├── bootstrap.sh       # Install Node + Claude Code on VM
│   ├── setup-openclaw.sh  # Claude Code installs OpenClaw
│   ├── setup-tailscale.sh # Claude Code installs Tailscale
│   ├── setup-skills.sh    # Configure whisper, clawhub
│   ├── setup-monitoring.sh # Healthcheck timer
│   ├── verify.sh          # Run all checks
│   ├── status.sh          # Check instance status
│   ├── list.sh            # List instances
│   └── destroy.sh         # Clean teardown
├── prompts/
│   ├── setup-openclaw.md  # Claude Code prompt for OpenClaw
│   └── setup-tailscale.md # Claude Code prompt for Tailscale
├── templates/
│   └── openclaw.json      # Base gateway config
└── instances/             # Runtime state (gitignored)
```

---

## Script Patterns

### SSH and Run Command
```bash
ssh -i "$SSH_KEY" "openclaw@$IP" "command here"
```

### SSH and Run Claude Code
```bash
ssh -i "$SSH_KEY" "openclaw@$IP" "ANTHROPIC_API_KEY=$KEY claude --print 'prompt here'"
```

### Check Exit Code
```bash
if ! some_command; then
  echo "ERROR: command failed"
  exit 1
fi
```

---

## Workflow

1. Find next `passes: false` in specs/prd-v1.json
2. Write the script/file
3. Code review: does it follow the patterns?
4. Update specs/progress.txt
5. Set passes: true
6. Commit and push

---

## End-to-End Coverage

The scripts must handle:
- VM provisioning (Hetzner)
- Node.js + Claude Code CLI installation
- OpenClaw installation and configuration
- Tailscale for secure remote access
- OpenAI Whisper skill configuration
- ClawdHub CLI installation
- Health monitoring (systemd timer)
- Full verification checklist
- Clean teardown

---

## Completion

When all 14 tasks pass:
```
<promise>COMPLETE</promise>
```
