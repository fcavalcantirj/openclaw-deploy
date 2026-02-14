---
name: openclaw-deploy
version: 1.1.0
description: "Fleet management for OpenClaw Gateway instances on Hetzner Cloud. Provisions, monitors, diagnoses, and self-heals child instances with dedicated Telegram bots. Use when deploying instances, managing fleet, diagnosing issues, onboarding users, or checking fleet health."
triggers:
  - deploy
  - fleet
  - hetzner
  - child
  - instance
  - provision
  - onboard
  - monitor
  - resuscitate
  - claw
metadata: {"openclaw": {"requires": {"bins": ["hcloud", "jq", "ssh", "curl"], "env": ["HCLOUD_TOKEN"]}, "primaryEnv": "HCLOUD_TOKEN"}}
---

# openclaw-deploy

> Fleet management for OpenClaw Gateway on Hetzner Cloud. Deploy, monitor, diagnose, and self-heal child instances.

---

## On Activation

When this skill activates, orient yourself:

1. Run `SKILL_DIR/claw list` to see the current fleet
2. If the command fails:
   - Check `hcloud context list` — is there an active context?
   - Check `SKILL_DIR/instances/credentials.json` exists
   - Guide the user through prerequisites (see `SKILL_DIR/references/deployment.md`)
3. If the fleet is empty:
   - Ask if the user wants to deploy their first instance
   - They need: a Telegram bot token from @BotFather and credentials.json configured
4. If instances exist:
   - Report the fleet summary (count, statuses)
   - Ask what the user wants to do

---

## Decision Routing

Match the user's intent to the right command. All commands use `SKILL_DIR/claw`.

| Intent | Command | Example |
|--------|---------|---------|
| Deploy a new instance | `claw deploy` | `SKILL_DIR/claw deploy --name alice --bot-token "123:ABC..."` |
| Import existing server | `claw import` | `SKILL_DIR/claw import NAME IP SSH_KEY` |
| List all instances | `claw list` | `SKILL_DIR/claw list` |
| Check instance health | `claw status` | `SKILL_DIR/claw status alice` |
| Approve Telegram pairing | `claw approve` | `SKILL_DIR/claw approve alice 3R7YX6KS` |
| Send message to child | `claw message` | `SKILL_DIR/claw message alice "Hello!"` |
| View or follow logs | `claw logs` | `SKILL_DIR/claw logs alice -f` |
| Restart gateway | `claw restart` | `SKILL_DIR/claw restart alice` |
| Destroy instance | `claw destroy` | `SKILL_DIR/claw destroy alice` |
| Run health diagnostics | `claw diagnose` | `SKILL_DIR/claw diagnose alice` or `claw diagnose self` |
| Auto-fix issues | `claw fix` | `SKILL_DIR/claw fix alice` |
| Upgrade tool stack | `claw upgrade` | `SKILL_DIR/claw upgrade alice --dry-run` |
| Interactive Claude Code | `claw shell` | `SKILL_DIR/claw shell alice` |
| Direct SSH access | `claw ssh` | `SKILL_DIR/claw ssh alice` |

When the user says "diagnose" or reports a problem: run `claw diagnose NAME` first, then offer `claw fix NAME` if issues are found.

When the user says "deploy" or "new instance": confirm they have a bot token, then run `claw deploy`.

---

## Quick Reference

### Deploy a New Instance

```bash
# Prerequisites: credentials.json configured, bot token from @BotFather
SKILL_DIR/claw deploy --name NAME --bot-token "TOKEN"
```

Takes ~5 minutes. Provisions Hetzner VM, installs OpenClaw + AMCP + Tailscale, registers Solvr child account. After deploy, verify with `SKILL_DIR/claw status NAME`.

### Monitor Fleet

```bash
# List all instances
SKILL_DIR/claw list

# Check one instance
SKILL_DIR/claw status NAME

# Diagnose issues (runs 7 health checks + Solvr search)
SKILL_DIR/claw diagnose NAME
```

### Diagnose and Fix

```bash
# Run diagnostics
SKILL_DIR/claw diagnose NAME

# Auto-fix (searches Solvr, applies fixes, escalates after 3 failures)
SKILL_DIR/claw fix NAME
```

`claw fix` runs Claude Code on the child VM with a fix prompt. It searches Solvr for known solutions first. If fixes fail 3 times, it escalates to parent via Telegram and email.

### Onboard a User

1. User creates a bot via @BotFather, gives you the token
2. `SKILL_DIR/claw deploy --name NAME --bot-token TOKEN`
3. User messages the bot on Telegram
4. `SKILL_DIR/claw approve NAME PAIRING_CODE`

---

## Deploy Workflow

### Step by Step

1. **Get bot token**: User messages @BotFather on Telegram: `/newbot` -> follow prompts -> copy token
2. **Deploy**: `SKILL_DIR/claw deploy --name alice --bot-token "123456:ABC-DEF..."`
3. **Wait ~5 minutes**: VM provisioning, OpenClaw install, AMCP setup, Solvr registration
4. **Verify**: `SKILL_DIR/claw status alice`
5. **Onboard user**: User messages the bot -> `SKILL_DIR/claw approve alice CODE`

### What Gets Installed on Each VM

- Ubuntu 24.04, Node.js 22
- OpenClaw Gateway (loopback:18789, token auth, Telegram pairing)
- AMCP CLI + proactive-amcp (real KERI identity, watchdog, encrypted checkpoints)
- Tailscale VPN, UFW firewall (SSH only)
- Healthcheck systemd timer (5min interval)

### Deploy Flags

Key flags: `--name` (required), `--bot-token` (required), `--region` (default: nbg1).
Full flag reference: `SKILL_DIR/references/commands.md`

---

## Monitoring and Self-Healing

### Health Status Levels

| Status | Meaning | Action |
|--------|---------|--------|
| HEALTHY | All checks pass | Continue monitoring |
| DEGRADED | Issues detected | Run `claw diagnose NAME` |
| OFFLINE | Gateway not running | Run `claw restart NAME` then `claw fix NAME` |
| UNREACHABLE | Cannot SSH to VM | Check `hcloud server list`, VM may be down |

### Recovery Escalation

Follow this sequence — each step checks before continuing:

1. `claw restart NAME` — fixes most transient issues
2. `claw diagnose NAME` — identify the root cause
3. `claw fix NAME` — auto-fix with Solvr + Claude Code on-VM
4. After 3 fix failures: auto-escalates to parent Telegram + email
5. `claw destroy NAME` + `claw deploy` — last resort, fresh instance

### Self-Healing (claw fix)

`claw fix` does:
1. Runs `claw diagnose` internally
2. Searches Solvr for existing solutions to each error
3. Uploads a fix prompt to the child VM
4. Runs Claude Code on-VM to apply fixes
5. Reports: fixed count, escalated count
6. Sends summary to parent Telegram on success
7. Posts new problems/approaches to Solvr for future agents

---

## Key Paths and Config

All paths relative to `SKILL_DIR`:

| Path | Purpose |
|------|---------|
| `SKILL_DIR/claw` | CLI dispatcher (entry point) |
| `SKILL_DIR/instances/` | Per-child: metadata.json, SSH keys |
| `SKILL_DIR/instances/credentials.json` | Shared secrets (gitignored) |
| `SKILL_DIR/templates/openclaw.json` | Base gateway config template |
| `SKILL_DIR/templates/fix-prompt.md` | Fix prompt template for `claw fix` |
| `SKILL_DIR/templates/diagnose-prompt.md` | Diagnose prompt template |
| `SKILL_DIR/scripts/` | Individual command scripts |
| `SKILL_DIR/prompts/` | Claude Code setup prompts for on-VM use |

---

## References

For detailed documentation:

- **All 14 commands with flags and examples**: `SKILL_DIR/references/commands.md`
- **Prerequisites, architecture, deploy flow**: `SKILL_DIR/references/deployment.md`
- **Common issues, recovery, security model**: `SKILL_DIR/references/troubleshooting.md`

---

## Prerequisites

- `hcloud` CLI with active context (Hetzner API token)
- `jq`, `ssh`, `curl` installed
- `SKILL_DIR/instances/credentials.json` with at least `anthropic_api_key` and Telegram credentials
- A Telegram bot token per child instance (from @BotFather)
