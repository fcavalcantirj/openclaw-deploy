#!/usr/bin/env bash
# ============================================================================
# healthcheck.sh — Runs ON the deployed VM every 5 minutes
# Auto-restarts gateway if down, monitors resources, rotates logs
# ============================================================================
set -euo pipefail

LOGFILE="$HOME/logs/healthcheck.log"
mkdir -p "$(dirname "$LOGFILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
  echo "$(timestamp) $1" >> "$LOGFILE"
}

# ── Check Gateway ─────────────────────────────────────────────────────────
if openclaw gateway status &>/dev/null; then
  log "✓ Gateway running"
else
  log "✗ Gateway DOWN — attempting restart..."
  openclaw gateway restart >> "$LOGFILE" 2>&1 || true
  
  sleep 5
  if openclaw gateway status &>/dev/null; then
    log "✓ Gateway recovered after restart"
  else
    log "✗ CRITICAL: Gateway failed to restart"
  fi
fi

# ── Check Systemd Service ─────────────────────────────────────────────────
if systemctl --user is-active openclaw-gateway &>/dev/null; then
  log "✓ Systemd service active"
else
  log "⚠ Systemd service not active — starting..."
  systemctl --user start openclaw-gateway || true
fi

# ── Check Tailscale ───────────────────────────────────────────────────────
if command -v tailscale &>/dev/null; then
  if tailscale status &>/dev/null; then
    log "✓ Tailscale connected"
  else
    log "⚠ Tailscale disconnected"
  fi
fi

# ── Check Disk Usage ──────────────────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_PCT" -gt 85 ]; then
  log "⚠ Disk usage HIGH: ${DISK_PCT}%"
elif [ "$DISK_PCT" -gt 70 ]; then
  log "⚠ Disk usage elevated: ${DISK_PCT}%"
else
  log "✓ Disk usage OK: ${DISK_PCT}%"
fi

# ── Check Memory ──────────────────────────────────────────────────────────
MEM_PCT=$(free | awk 'NR==2 {printf "%.0f", $3/$2*100}')
if [ "$MEM_PCT" -gt 85 ]; then
  log "⚠ Memory usage HIGH: ${MEM_PCT}%"
elif [ "$MEM_PCT" -gt 70 ]; then
  log "⚠ Memory usage elevated: ${MEM_PCT}%"
else
  log "✓ Memory usage OK: ${MEM_PCT}%"
fi

# ── Check Load Average ────────────────────────────────────────────────────
LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
LOAD_INT=${LOAD%.*}
if [ "${LOAD_INT:-0}" -gt 2 ]; then
  log "⚠ Load average HIGH: $LOAD"
else
  log "✓ Load average OK: $LOAD"
fi

# ── Log Rotation ──────────────────────────────────────────────────────────
# Rotate if log > 10MB
if [ -f "$LOGFILE" ]; then
  SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || stat -f%z "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 10485760 ]; then
    mv "$LOGFILE" "${LOGFILE}.$(date +%Y%m%d).old"
    log "Log rotated"
  fi
fi
