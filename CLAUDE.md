# OpenClaw Deploy — Project Guidelines

## Overview

Autonomous provisioning and configuration of OpenClaw Gateway instances on Hetzner Cloud.

## Golden Rules

### 1. Test Before Marking Done

**Verify each step actually works before marking passes=true.**

```bash
# Example: verify hcloud works
hcloud server list  # Must succeed, not just "installed"
```

### 2. Real Implementation Only

**NO placeholders. NO "will be added later". Everything must work.**

- If a script needs to exist, write the full script
- If a config needs values, use real values (or documented placeholders)
- If verification is needed, run the actual commands

### 3. Security First

- Never commit credentials
- Gateway binds to loopback only
- UFW denies all except SSH
- Tailscale for remote access

### 4. Document As You Go

- Update `specs/progress.txt` with what you did
- Keep QUICKREF.md current
- Comments in scripts explain why, not what

---

## File Structure

```
openclaw-deploy/
├── CLAUDE.md              # This file (project guidelines)
├── SPEC.md                # Full technical specification
├── README.md              # User-facing quick start
├── specs/
│   ├── prd-v1.json        # Requirements (passes: true/false)
│   └── progress.txt       # Progress notes
├── scripts/
│   ├── provision.sh       # Create Hetzner VM
│   ├── bootstrap.sh       # Install Node + Claude Code on VM
│   ├── deploy.sh          # Master orchestration
│   ├── status.sh          # Check instance status
│   ├── list.sh            # List all instances
│   ├── destroy.sh         # Remove instance
│   └── healthcheck.sh     # Monitoring (runs on VM)
├── prompts/
│   └── setup-openclaw.md  # Claude Code prompt for VM setup
├── templates/
│   └── openclaw.json      # Base OpenClaw config
├── instances/             # Per-instance state (gitignored)
│   ├── credentials.json   # API keys (gitignored)
│   └── {name}/
│       └── metadata.json
├── ralph.sh               # Task runner
└── progress.sh            # Progress tracker
```

---

## Workflow

### Working on a Requirement

1. **Read `specs/prd-v1.json`** — find next `"passes": false`
2. **Read `SPEC.md`** — understand full context for that component
3. **Implement** — write/update scripts, configs, prompts
4. **Test** — run the actual commands, verify they work
5. **Update `specs/progress.txt`** — note what you did
6. **Update `specs/prd-v1.json`** — set `"passes": true`
7. **Commit and push**

### Commit Message Format

```
feat(provision): implement VM creation script

- Add hcloud server create with SSH key
- Add metadata.json generation
- Tested: created test VM successfully
```

---

## Commands Reference

### hcloud (VM management)
```bash
export PATH="$HOME/bin:$PATH"
hcloud server list
hcloud server create --name NAME --type cx22 --image ubuntu-24.04 --location nbg1 --ssh-key KEY
hcloud server delete NAME
hcloud server ip NAME
```

### SSH to VM
```bash
ssh -i ~/.ssh/openclaw_NAME root@IP
ssh -i ~/.ssh/openclaw_NAME openclaw@IP
```

### Claude Code on VM
```bash
ANTHROPIC_API_KEY=sk-ant-... claude --print "$(cat setup-prompt.md)"
```

### Progress Tracking
```bash
./progress.sh  # Shows X/14 (Y%)
```

---

## Credentials

| Credential | Location | Notes |
|------------|----------|-------|
| Hetzner | ~/.config/hcloud/cli.toml | Configured via hcloud CLI |
| Anthropic | instances/credentials.json | For Claude Code on VMs |
| OpenAI | ~/.openclaw/openclaw.json | For whisper skill |

**All credentials are gitignored. Never commit them.**

---

## Important Notes

1. **Read SPEC.md** — it has full details for each component
2. **One task at a time** — complete and verify before moving on
3. **Test proves completion** — if it works, mark it done
4. **Ask if unclear** — better to clarify than assume wrong
