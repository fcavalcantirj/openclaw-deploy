# claw — Command Reference

All commands use `SKILL_DIR/claw <command>`. The `claw` CLI dispatches to individual scripts in `SKILL_DIR/scripts/`.

---

## Deployment

### deploy

Provision a new child instance on Hetzner Cloud. Takes ~5 minutes.

```bash
SKILL_DIR/claw deploy --name NAME --bot-token TOKEN [OPTIONS]
```

| Flag | Description | Default |
|------|-------------|---------|
| `--name NAME` | Instance name (required) | — |
| `--bot-token TOKEN` | Telegram bot token (required) | — |
| `--region REGION` | Hetzner region: nbg1, fsn1, hel1, ash | nbg1 |
| `--type TYPE` | Server type | cx23 |
| `--skip-tailscale` | Skip Tailscale VPN setup | — |
| `--skip-skills` | Skip optional skills (Whisper) | — |
| `--skip-monitoring` | Skip healthcheck timer | — |
| `--checkpoint-interval` | AMCP checkpoint interval | 1h |
| `--parent-solvr-name NAME` | Override parent Solvr name | — |
| `--parent-telegram-token TOKEN` | Override parent Telegram token | — |
| `--parent-chat-id ID` | Override parent chat ID | — |
| `--parent-email EMAIL` | Override parent email | — |

Example:
```bash
SKILL_DIR/claw deploy --name alice-bot --bot-token "123456:ABC-DEF..." --region fsn1
```

### import

Import an existing server as a managed instance (no provisioning).

```bash
SKILL_DIR/claw import NAME IP SSH_KEY_PATH
```

Example:
```bash
SKILL_DIR/claw import legacy-bot 1.2.3.4 ~/.ssh/legacy_key
```

### destroy

Tear down an instance: deletes Hetzner VM, SSH keys, and local metadata.

```bash
SKILL_DIR/claw destroy NAME
```

Prompts for confirmation internally (`--confirm` passed automatically by claw).

---

## Fleet Overview

### list

List all deployed instances with name, IP, region, and status.

```bash
SKILL_DIR/claw list
```

Output: table with NAME, IP, REGION, STATUS columns.

### status

Show detailed health status for a single instance.

```bash
SKILL_DIR/claw status NAME
```

Checks: SSH connectivity, gateway service, OpenClaw CLI, error logs, disk, memory.

---

## User Management

### approve

Approve a Telegram DM pairing request by code.

```bash
SKILL_DIR/claw approve NAME CODE
```

Example:
```bash
SKILL_DIR/claw approve alice-bot 3R7YX6KS
```

The pairing code is displayed when a user messages the bot for the first time (DM pairing mode).

### message

Send a message to a child instance's active session.

```bash
SKILL_DIR/claw message NAME "text"
```

Example:
```bash
SKILL_DIR/claw message alice-bot "Hello from parent!"
```

---

## Control

### logs

View child instance gateway logs.

```bash
SKILL_DIR/claw logs NAME [-f]
```

| Flag | Description |
|------|-------------|
| `-f` | Follow logs in real-time |

Shows last 50 lines by default. Use `-f` for live tail.

### restart

Restart the OpenClaw Gateway service on a child instance.

```bash
SKILL_DIR/claw restart NAME
```

Safe restart with post-restart verification.

### upgrade

Upgrade the tool stack (OpenClaw, Node, AMCP) on a child instance.

```bash
SKILL_DIR/claw upgrade NAME [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--dry-run` | Show what would be upgraded without making changes |

---

## Monitoring & Recovery

### diagnose

Run health diagnostics on a child instance (or self). Uses proactive-amcp diagnose on-VM, which runs 7 checks and searches Solvr for known solutions.

```bash
SKILL_DIR/claw diagnose NAME
SKILL_DIR/claw diagnose self
```

- `NAME`: runs proactive-amcp diagnose remotely via SSH
- `self`: runs proactive-amcp diagnose locally on parent

Output: structured JSON with checks_passed, checks_failed, errors, solvr_matches.

### fix

Attempt to auto-fix issues found by diagnose. Runs Claude Code on-VM with a fix prompt template. Searches Solvr for existing solutions, applies fixes, and escalates to parent Telegram/email after 3 failures.

```bash
SKILL_DIR/claw fix NAME
```

Flow:
1. Runs diagnose internally
2. If issues found, uploads fix prompt to VM
3. Claude Code applies fixes on-VM
4. Reports fixed/escalated counts
5. Sends Telegram summary to parent

---

## Remote Access

### shell

Open an interactive Claude Code session on a child instance.

```bash
SKILL_DIR/claw shell NAME
```

Requires `ANTHROPIC_API_KEY` in `SKILL_DIR/instances/credentials.json` or environment. Runs Claude Code with `--dangerously-skip-permissions` in the child's workspace.

### ssh

SSH directly into a child instance for manual debugging.

```bash
SKILL_DIR/claw ssh NAME
```

Uses the SSH key stored in the instance metadata.

---

## Command Quick-Reference Table

| Command | Arguments | Purpose |
|---------|-----------|---------|
| `deploy` | `--name N --bot-token T` | Provision new child |
| `import` | `NAME IP SSH_KEY` | Import existing server |
| `list` | — | Show all instances |
| `status` | `NAME` | Health check one instance |
| `approve` | `NAME CODE` | Approve Telegram pairing |
| `message` | `NAME "text"` | Send message to child |
| `logs` | `NAME [-f]` | View/follow logs |
| `restart` | `NAME` | Restart gateway |
| `destroy` | `NAME` | Tear down instance |
| `diagnose` | `NAME\|self` | Run health diagnostics |
| `fix` | `NAME` | Auto-fix with escalation |
| `upgrade` | `NAME [--dry-run]` | Upgrade tool stack |
| `shell` | `NAME` | Interactive Claude Code |
| `ssh` | `NAME` | Direct SSH access |
