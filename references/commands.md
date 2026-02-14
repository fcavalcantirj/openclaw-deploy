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

Run comprehensive health diagnostics on a child instance (or self). Two-layer architecture: parent-side SSH check, then single SSH batch collecting 14 checks.

```bash
SKILL_DIR/claw diagnose NAME          # human-readable colored report
SKILL_DIR/claw diagnose NAME --json   # machine-consumable JSON
SKILL_DIR/claw diagnose self          # local self-diagnosis
```

| Flag | Description |
|------|-------------|
| `--json` | Output machine-consumable JSON instead of colored report |

Checks (13 total):
1. SSH connectivity, 2. Gateway process, 3. Health endpoint, 4. Session corruption, 5. Config JSON validity, 6. Disk space, 7. Memory, 8. Claude Code CLI, 9. Claude Code auth (OAuth), 10. Anthropic API key validity, 11. User mismatch, 12. AMCP identity, 13. AMCP config completeness + last checkpoint age.

Default output: human-readable colored report grouped by category (Connectivity, Authentication, AMCP, System). Use `--json` for backward-compatible JSON with `checks_passed`, `checks_failed`, `checks`, `errors`.

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

## AMCP Management

### setup-amcp

One-command AMCP bootstrap on a child instance. Each step is idempotent.

```bash
SKILL_DIR/claw setup-amcp NAME [--force] [--dry-run]
```

| Flag | Description |
|------|-------------|
| `--force` | Recreate identity even if one exists |
| `--dry-run` | Preview what would be done without making changes |

Steps performed:
1. SSH connectivity check
2. Install amcp CLI (if missing)
3. Install proactive-amcp (if missing)
4. Create AMCP identity (real KERI, skips if exists unless `--force`)
5. Push config from parent credentials.json
6. Install watchdog service (if not active)
7. Run first checkpoint
8. Update instance metadata

Example:
```bash
SKILL_DIR/claw setup-amcp jack --dry-run    # Preview
SKILL_DIR/claw setup-amcp jack              # Full bootstrap
SKILL_DIR/claw setup-amcp jack --force      # Recreate identity
```

### config

View or set AMCP config (`~/.amcp/config.json`) on a child instance.

```bash
SKILL_DIR/claw config NAME                  # default: --show
SKILL_DIR/claw config NAME --show           # display config (secrets masked)
SKILL_DIR/claw config NAME --set key=value  # set a single key
SKILL_DIR/claw config NAME --push           # bulk push from credentials.json
```

| Flag | Description |
|------|-------------|
| `--show` | Display config with secrets masked (default) |
| `--set key=val` | Set a single config key via proactive-amcp |
| `--push` | Bulk push keys from local credentials.json |

Key mapping for `--push` (credentials.json key -> AMCP config key):
- `pinata_jwt` -> `pinata_jwt`
- `anthropic_api_key` -> `anthropic.apiKey`
- `solvr_api_key` -> `solvr_api_key`
- `parent_telegram_bot_token` -> `parent_bot_token`
- `parent_telegram_chat_id` -> `parent_chat_id`
- `agentmail_api_key` -> `notify.agentmailApiKey`
- `notify_email` -> `notify.emailTo`

### checkpoint

Trigger an AMCP checkpoint on a child instance.

```bash
SKILL_DIR/claw checkpoint NAME [--full]
```

| Flag | Description |
|------|-------------|
| `--full` | Full checkpoint with secrets (default: quick checkpoint) |

Detects service user and runs checkpoint as the correct user. Reports CID and updates instance metadata.

---

## Remote Access

### shell

Open an interactive Claude Code session on a child instance.

```bash
SKILL_DIR/claw shell NAME
```

Requires `ANTHROPIC_API_KEY` in `SKILL_DIR/instances/credentials.json` or environment. Opens an interactive Claude Code session in the child's workspace. The user must explicitly request this command.

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
| `diagnose` | `NAME\|self [--json]` | Run 13 health checks |
| `fix` | `NAME` | Auto-fix with escalation |
| `upgrade` | `NAME [--dry-run]` | Upgrade tool stack |
| `setup-amcp` | `NAME [--force\|--dry-run]` | Bootstrap AMCP on child |
| `config` | `NAME [--show\|--set\|--push]` | View/set AMCP config |
| `checkpoint` | `NAME [--full]` | Run checkpoint on child |
| `shell` | `NAME` | Interactive Claude Code |
| `ssh` | `NAME` | Direct SSH access |
