# OpenClaw Deploy — Project Guidelines

## Overview

Autonomous provisioning of OpenClaw Gateway instances on Hetzner Cloud, configured via Claude Code.

**This is a scripts + prompts project, NOT a Go/React app.**

---

## Golden Rules

### 1. Verify Before Marking Done

**Every step must be TESTED, not just written.**

```bash
# Wrong: "I wrote the script" → passes: true
# Right: "I ran the script, it worked" → passes: true

# Example: verify hcloud
hcloud server list  # Must return list, not error

# Example: verify SSH
ssh -o ConnectTimeout=5 root@IP 'echo ok'  # Must echo "ok"
```

### 2. Real Implementation Only

**NO placeholders. NO "TODO". Everything must work end-to-end.**

- Script must run without errors
- Config must have real values (or documented env vars)
- Prompts must be complete and tested

### 3. File Size Limit — 800 Lines Max

**No script or config file over 800 lines.** Split if needed.

Check: `wc -l scripts/*.sh prompts/*.md`

### 4. Security First

- **Gateway binds to loopback only** — never 0.0.0.0
- **UFW denies all except SSH** — no port 18789 exposed
- **Tailscale for remote access** — encrypted tunnel
- **Credentials NEVER committed** — use .gitignore

### 5. One Task At A Time

**Complete one requirement fully before moving to the next.**

Don't partially implement multiple tasks. Finish, verify, commit, then move on.

### 6. Update Progress On Every Iteration

**After each task, update `specs/progress.txt` with:**
- Date
- What you did
- What worked / what didn't
- Next steps

---

## Workflow (Every Iteration)

```
1. READ specs/prd-v1.json → find next passes: false
2. READ SPEC.md → understand that component fully
3. IMPLEMENT → write/update scripts, configs, prompts
4. TEST → actually run it, verify it works
5. UPDATE specs/progress.txt → document what you did
6. UPDATE specs/prd-v1.json → set passes: true
7. COMMIT → git add . && git commit -m "feat(category): description"
8. PUSH → git push
```

---

## File Structure

```
openclaw-deploy/
├── CLAUDE.md              # THIS FILE - read first
├── SPEC.md                # Full technical specification
├── README.md              # User quick-start guide
├── specs/
│   ├── prd-v1.json        # Requirements (passes: true/false)
│   └── progress.txt       # Progress notes (UPDATE EVERY ITERATION)
├── scripts/
│   ├── provision.sh       # Create Hetzner VM
│   ├── bootstrap.sh       # Install Node + Claude Code on VM
│   ├── deploy.sh          # Master orchestration (interactive)
│   ├── status.sh          # Check instance status
│   ├── list.sh            # List all instances
│   ├── destroy.sh         # Remove instance safely
│   └── healthcheck.sh     # Monitoring script (runs ON VM)
├── prompts/
│   └── setup-openclaw.md  # Claude Code prompt for VM setup
├── templates/
│   └── openclaw.json      # Base OpenClaw Gateway config
├── instances/             # Runtime state (gitignored)
│   ├── credentials.json   # API keys (NEVER COMMIT)
│   └── {name}/
│       └── metadata.json  # Instance state
├── ralph.sh               # Single-batch task runner
├── ralph-continues.sh     # Continuous runner with pauses
└── progress.sh            # Shows X/14 (Y%)
```

---

## Running Ralph

### Single batch (N iterations)
```bash
./ralph.sh 5
```

### Continuous (batches with pauses)
```bash
# Defaults: 3 iterations, 15 min pause
./ralph-continues.sh

# Custom
BATCH_SIZE=5 BATCH_PAUSE_MINS=10 ./ralph-continues.sh
```

### Check progress
```bash
./progress.sh  # Output: 3/14 (21%)
```

---

## Commands Reference

### hcloud (VM provisioning)
```bash
export PATH="$HOME/bin:$PATH"
hcloud server list
hcloud server create --name NAME --type cx22 --image ubuntu-24.04 --location nbg1 --ssh-key KEY
hcloud server ip NAME
hcloud server delete NAME
hcloud ssh-key create --name KEY --public-key-from-file ~/.ssh/KEY.pub
```

### SSH to VM
```bash
ssh -i ~/.ssh/openclaw_NAME root@IP        # As root
ssh -i ~/.ssh/openclaw_NAME openclaw@IP    # As openclaw user
```

### Run Claude Code on VM
```bash
# Set key and run
ANTHROPIC_API_KEY=$(cat instances/credentials.json | jq -r .anthropic_api_key)
ssh openclaw@IP "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY claude --print '$(cat prompts/setup-openclaw.md)'"
```

### Instance management
```bash
./scripts/list.sh                    # List all instances
./scripts/status.sh instance-name    # Detailed status
./scripts/destroy.sh instance-name   # Delete (requires --confirm)
```

---

## Credentials

| Credential | Location | Notes |
|------------|----------|-------|
| Hetzner API | ~/.config/hcloud/cli.toml | Configured via `hcloud context` |
| Anthropic | instances/credentials.json | For Claude Code on VMs |
| OpenAI | ~/.openclaw/openclaw.json | For whisper skill |

**All in .gitignore. NEVER commit credentials.**

---

## Testing Checklist

Before marking a task as `passes: true`, verify:

| Component | Test Command | Expected |
|-----------|--------------|----------|
| hcloud | `hcloud server list` | Returns list (no error) |
| SSH key | `ls ~/.ssh/openclaw_*` | Key files exist |
| VM creation | `hcloud server describe NAME` | Shows running |
| SSH access | `ssh root@IP 'echo ok'` | Prints "ok" |
| Node on VM | `ssh root@IP 'node -v'` | v22.x.x |
| Claude Code | `ssh root@IP 'which claude'` | Path returned |
| OpenClaw | `ssh openclaw@IP 'openclaw --version'` | Version shown |
| Gateway | `ssh openclaw@IP 'openclaw gateway status'` | Running |
| Tailscale | `ssh root@IP 'tailscale status'` | Connected |
| UFW | `ssh root@IP 'ufw status'` | Active |

---

## Commit Message Format

```
feat(provision): implement VM creation with SSH key upload

- Generate ed25519 key if not exists
- Upload to Hetzner via hcloud ssh-key create
- Create cx22 server in nbg1
- Tested: successfully created test-vm-01
```

Categories: `infrastructure`, `provision`, `setup`, `networking`, `channels`, `monitoring`, `verification`, `teardown`, `scripts`, `security`, `documentation`

---

## When Complete

When ALL 14 tasks have `passes: true`, output:

```
<promise>COMPLETE</promise>
```

Ralph detects this and stops.

---

## Important Reminders

1. **READ SPEC.md** — it has full details for each component
2. **TEST everything** — scripts must actually work
3. **ONE task at a time** — don't skip ahead
4. **UPDATE progress.txt** — every single iteration
5. **COMMIT after each task** — small, verified commits
6. **NO credentials in git** — ever
