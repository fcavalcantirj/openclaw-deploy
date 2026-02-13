You are setting up an OpenClaw Gateway on a fresh Ubuntu 24.04 Hetzner Cloud VM. The bootstrap has already installed Node 22, npm, and basic system packages. You are running as the `openclaw` user with sudo access.

Your job is to complete the full setup. Follow these phases IN ORDER. After each phase, verify it worked before moving on. If something fails, debug it — read logs, check versions, retry.

---

## PHASE 1: Install OpenClaw

```bash
npm install -g openclaw@latest
```

Verify: `openclaw --version` should return a version number.

Then run the onboarding in non-interactive mode. We want the daemon installed as a systemd user service:

```bash
openclaw onboard --install-daemon
```

If `--install-daemon` doesn't work as a flag, try:

```bash
openclaw gateway install
systemctl --user enable --now openclaw-gateway.service
sudo loginctl enable-linger openclaw
```

Verify: `openclaw gateway status` should show the gateway is running.

---

## PHASE 2: Configure OpenClaw

The config file lives at `~/.openclaw/openclaw.json` (JSON5 format).

Read the existing config first, then merge in these settings. The config should include:

```json5
{
  gateway: {
    bind: "loopback",          // SECURITY: never expose to public internet
    port: 18789,
    auth: {
      mode: "token",           // require token for all connections
    },
  },
  channels: {
    telegram: {
      enabled: true,
      // botToken will be set by the user later via:
      //   openclaw config set channels.telegram.botToken "YOUR_TOKEN"
      // OR by editing ~/.openclaw/openclaw.json directly
      dmPolicy: "pairing",     // owner must approve each new DM sender
      groups: {
        "*": { requireMention: true },
      },
    },
  },
  logging: {
    redactSensitive: true,     // don't leak tokens in logs
  },
}
```

IMPORTANT: Do NOT hardcode any bot tokens. Leave a placeholder comment. The user will add their Telegram bot token after this setup.

After writing the config, restart the gateway:

```bash
openclaw gateway restart
openclaw gateway status
```

Also enable the OpenAI-compatible HTTP endpoint so the user can hit it programmatically later:

```json5
{
  gateway: {
    http: {
      endpoints: {
        chatCompletions: { enabled: true },
      },
    },
  },
}
```

Merge this into the existing config, don't overwrite.

---

## PHASE 3: Install and Configure Tailscale

Tailscale gives the user secure remote access to the Gateway without exposing port 18789.

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
```

Start Tailscale — it will print an auth URL. The user will need to visit this URL to authenticate:

```bash
sudo tailscale up
```

After Tailscale is running, verify connectivity:

```bash
tailscale status
```

IMPORTANT NOTE TO USER: After Tailscale is authenticated, you can access the OpenClaw Gateway from any device on your tailnet:

```bash
# From your laptop (on the same tailnet):
ssh openclaw@<tailscale-ip>
# Or access the Control UI:
# http://<tailscale-ip>:18789/openclaw
```

Optionally, if the `openclaw gateway --tailscale serve` command exists, try it — it auto-configures Tailscale Serve for HTTPS access to the Gateway dashboard.

---

## PHASE 4: Set Up Monitoring

Create a simple but effective monitoring stack:

### 4a. Gateway Health Check Script

Create `/home/openclaw/scripts/healthcheck.sh`:

```bash
#!/usr/bin/env bash
# OpenClaw Gateway Health Check
set -euo pipefail

LOGFILE="/home/openclaw/logs/healthcheck.log"
mkdir -p "$(dirname "$LOGFILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Check if gateway process is running
if openclaw gateway status &>/dev/null; then
  echo "$(timestamp) ✓ Gateway is running" >> "$LOGFILE"
else
  echo "$(timestamp) ✗ Gateway is DOWN — attempting restart..." >> "$LOGFILE"
  openclaw gateway restart 2>&1 >> "$LOGFILE"
  
  sleep 5
  if openclaw gateway status &>/dev/null; then
    echo "$(timestamp) ✓ Gateway recovered after restart" >> "$LOGFILE"
  else
    echo "$(timestamp) ✗ CRITICAL: Gateway failed to restart" >> "$LOGFILE"
  fi
fi

# Check disk usage
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_PCT" -gt 85 ]; then
  echo "$(timestamp) ⚠ Disk usage at ${DISK_PCT}%" >> "$LOGFILE"
fi

# Check memory
MEM_PCT=$(free | awk 'NR==2 {printf "%.0f", $3/$2*100}')
if [ "$MEM_PCT" -gt 85 ]; then
  echo "$(timestamp) ⚠ Memory usage at ${MEM_PCT}%" >> "$LOGFILE"
fi

# Rotate log if > 10MB
if [ -f "$LOGFILE" ] && [ "$(stat -f%z "$LOGFILE" 2>/dev/null || stat -c%s "$LOGFILE")" -gt 10485760 ]; then
  mv "$LOGFILE" "${LOGFILE}.old"
fi
```

Make it executable: `chmod +x /home/openclaw/scripts/healthcheck.sh`

### 4b. Systemd Timer for Health Checks (every 5 minutes)

Create `~/.config/systemd/user/openclaw-healthcheck.service`:

```ini
[Unit]
Description=OpenClaw Gateway Health Check

[Service]
Type=oneshot
ExecStart=/home/openclaw/scripts/healthcheck.sh
```

Create `~/.config/systemd/user/openclaw-healthcheck.timer`:

```ini
[Unit]
Description=Run OpenClaw health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Enable it:

```bash
mkdir -p ~/.config/systemd/user
# (create the files above)
systemctl --user daemon-reload
systemctl --user enable --now openclaw-healthcheck.timer
systemctl --user list-timers
```

### 4c. Log Rotation for OpenClaw Logs

Create `/etc/logrotate.d/openclaw` (needs sudo):

```
/tmp/openclaw/*.log /home/openclaw/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

---

## PHASE 5: Create a Quick-Reference Card

Create `/home/openclaw/QUICKREF.md` with:

```markdown
# OpenClaw Gateway — Quick Reference

## Status & Logs
```
openclaw gateway status
openclaw logs --follow
openclaw channels status --probe
systemctl --user status openclaw-gateway
```

## Telegram Bot Setup
1. Talk to @BotFather on Telegram, create a bot, get the token
2. Set the token:
   Edit ~/.openclaw/openclaw.json and set channels.telegram.botToken
   OR: openclaw config set channels.telegram.botToken "123:abc"
3. Restart: openclaw gateway restart
4. Message your bot on Telegram — you'll get a pairing code
5. Approve: openclaw pairing approve telegram <CODE>

## Send Messages
```
openclaw message send --channel telegram --target 123456789 --message "hello"
openclaw message send --channel telegram --target @username --message "hello"
```

## Agent Runs
```
openclaw agent --message "do something"
openclaw agent --to @username --message "status update" --deliver
```

## Tailscale
```
tailscale status
sudo tailscale up    # re-authenticate if needed
```

## Remote Access (from your laptop on the tailnet)
```
ssh openclaw@<tailscale-ip>
# Control UI: http://<tailscale-ip>:18789/openclaw
# SSH tunnel: ssh -N -L 18789:127.0.0.1:18789 openclaw@<tailscale-ip>
```

## Monitoring
```
cat ~/logs/healthcheck.log
systemctl --user list-timers
journalctl --user -u openclaw-gateway -f
```

## Config
- Config: ~/.openclaw/openclaw.json
- State: ~/.openclaw/
- Logs: /tmp/openclaw/ and ~/logs/
```

---

## FINAL VERIFICATION CHECKLIST

Run these and report the results:

1. `openclaw --version` — should return a version
2. `openclaw gateway status` — should show running
3. `tailscale status` — should show connected (or waiting for auth)
4. `systemctl --user is-active openclaw-gateway` — should say "active"
5. `systemctl --user list-timers` — should show openclaw-healthcheck.timer
6. `ufw status` — should show SSH allowed, everything else denied
7. `cat ~/.openclaw/openclaw.json` — should show the config (redact any tokens)

If any check fails, debug and fix it before reporting.

Print a summary at the end showing what's working and what needs the user's action (like adding the Telegram bot token and authenticating Tailscale).
