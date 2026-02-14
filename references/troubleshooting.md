# Troubleshooting

## Status Levels

| Status | Meaning | Typical Cause |
|--------|---------|---------------|
| **HEALTHY** | All checks passed | Normal operation |
| **DEGRADED** | Gateway running but issues detected | High error rate, disk space, memory pressure |
| **OFFLINE** | Gateway service not running | Crash, failed restart, config error |
| **UNREACHABLE** | Cannot SSH to VM | VM down, network issue, SSH key mismatch |

---

## Recovery Escalation Path

When an instance has issues, follow this sequence (each step checks if the problem is resolved before continuing):

```
1. restart   →  Restart gateway service
2. diagnose  →  Run health checks + Solvr search
3. fix       →  Apply fixes via Claude Code on-VM
4. resuscitate → AMCP multi-tier recovery (restart → config fix → full rehydrate)
5. destroy + redeploy → Last resort: fresh instance
```

Commands:
```bash
SKILL_DIR/claw restart NAME
SKILL_DIR/claw diagnose NAME
SKILL_DIR/claw fix NAME
# If fix fails 3 times, it auto-escalates to parent Telegram/email
```

---

## Common Issues

### "hcloud: command not found"

The Hetzner CLI is not installed.

```bash
brew install hcloud          # macOS
# Or download: https://github.com/hetznercloud/cli
```

### "No active context"

hcloud needs a configured context with your API token.

```bash
hcloud context create openclaw
hcloud context use openclaw
# Paste your Hetzner API token
```

### Instance won't start after deploy

Check the deploy logs and verify the instance came up:

```bash
SKILL_DIR/claw status NAME
SKILL_DIR/claw logs NAME
```

If gateway never started, SSH in and check manually:

```bash
SKILL_DIR/claw ssh NAME
# On VM:
systemctl status openclaw-gateway
journalctl -u openclaw-gateway -n 100 --no-pager
```

### Gateway not responding

```bash
# 1. Check status
SKILL_DIR/claw status NAME

# 2. Check logs for errors
SKILL_DIR/claw logs NAME

# 3. Restart
SKILL_DIR/claw restart NAME

# 4. If restart doesn't help, diagnose
SKILL_DIR/claw diagnose NAME
```

### High error rate in logs

```bash
# View recent errors
SKILL_DIR/claw logs NAME

# Run diagnostics (checks error rate, disk, memory, etc.)
SKILL_DIR/claw diagnose NAME

# Auto-fix if issues found
SKILL_DIR/claw fix NAME
```

### SSH connection refused

The VM may still be booting (after deploy) or the VM may be down.

```bash
# Check VM is running in Hetzner
hcloud server list

# If just deployed, wait 30s for SSH to become available
# If VM is running but SSH fails, check firewall:
SKILL_DIR/claw ssh NAME
# On VM: sudo ufw status
```

### Telegram bot not receiving messages

1. Verify bot token is valid: message @BotFather, check `/mybots`
2. Check gateway has the token configured:
   ```bash
   SKILL_DIR/claw ssh NAME
   # On VM: cat ~/.openclaw/openclaw.json | jq '.channels.telegram'
   ```
3. Ensure gateway is running: `SKILL_DIR/claw status NAME`

### Pairing code not working

```bash
# List pending pairing requests
SKILL_DIR/claw ssh NAME
# On VM: OPENCLAW_GATEWAY_TOKEN="..." openclaw pairing list telegram
```

Codes expire after a timeout. Have the user message the bot again to generate a new code.

### Disk space issues

```bash
SKILL_DIR/claw ssh NAME
# On VM:
df -h
journalctl --vacuum-time=7d    # Clean old logs
rm -rf /tmp/claw-*             # Clean temp files
```

### Configuration problems

```bash
SKILL_DIR/claw ssh NAME
# On VM:
cat ~/.openclaw/openclaw.json | jq .    # Validate JSON
cat ~/.amcp/config.json | jq .          # Check AMCP config
systemctl status openclaw-gateway       # Check service
```

---

## Security Model

### Network

- Gateway binds to **loopback only** (127.0.0.1:18789) — never public
- UFW firewall allows SSH only (port 22)
- Tailscale VPN for secure remote access (optional)
- No public HTTP/HTTPS ports exposed

### Authentication

- Token-based auth for gateway API
- DM pairing policy for Telegram (users must be approved)
- SSH key authentication (no passwords)
- Per-instance SSH keys stored in `SKILL_DIR/instances/{name}/`

### Credentials

- `SKILL_DIR/instances/credentials.json` is gitignored
- API keys passed via CLI flags or config (never hardcoded)
- Bot tokens stored only on child VMs
- AMCP identity keys never leave the child VM

### Credential Rotation

```bash
# Rotate Telegram bot token
# 1. Get new token from @BotFather (/revoke on old bot)
# 2. Update on child:
SKILL_DIR/claw ssh NAME
# On VM: update ~/.openclaw/openclaw.json with new token, restart gateway
```
