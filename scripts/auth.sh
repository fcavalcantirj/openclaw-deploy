#!/usr/bin/env bash
# =============================================================================
# auth.sh — Show/switch auth mode (API key vs OAuth) on a child instance
# =============================================================================
# Usage:
#   ./scripts/auth.sh NAME              # show current auth mode
#   ./scripts/auth.sh NAME --mode oauth  # switch to OAuth
#   ./scripts/auth.sh NAME --mode apikey # switch to API key
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [--mode oauth|apikey]

Show or switch the authentication mode on a child instance.
Patches auth-profiles.json, sessions.json (authProfileOverride), and restarts the gateway.

Arguments:
  NAME              Instance name

Options:
  --mode oauth      Switch to OAuth (requires prior 'claude login' on child)
  --mode apikey     Switch to API key

Examples:
  $(basename "$0") jack               # show current auth mode
  $(basename "$0") jack --mode oauth   # switch to OAuth
  $(basename "$0") jack --mode apikey  # switch to API key

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      shift
      [[ $# -lt 1 ]] && { log_error "--mode requires oauth or apikey"; usage; }
      MODE="$1"
      if [[ "$MODE" != "oauth" && "$MODE" != "apikey" ]]; then
        log_error "Invalid mode '$MODE'. Must be oauth or apikey"; exit 1
      fi
      shift
      ;;
    -h|--help) usage ;;
    *)
      if [[ -z "$INSTANCE_NAME" ]]; then
        INSTANCE_NAME="$1"; shift
      else
        log_error "Unknown argument: $1"; usage
      fi
      ;;
  esac
done

[[ -z "$INSTANCE_NAME" ]] && usage

# ── Load instance + verify SSH ───────────────────────────────────────────────

load_instance "$INSTANCE_NAME" || exit 1

if ! ssh_check "$INSTANCE_NAME" 10 2>/dev/null; then
  log_error "Cannot reach $INSTANCE_NAME via SSH"
  exit 1
fi

# ── Detect service user home ─────────────────────────────────────────────────
# Files live under the openclaw service user, not root

detect_service_home() {
  ssh_exec "$INSTANCE_NAME" "
    for u in openclaw clawdbot \$(whoami); do
      h=\$(getent passwd \"\$u\" 2>/dev/null | cut -d: -f6)
      if [[ -n \"\$h\" && -d \"\$h/.openclaw\" ]]; then echo \"\$h\"; exit 0; fi
    done
    # Fallback: find who owns .openclaw
    h=\$(find /home -maxdepth 2 -name '.openclaw' -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    [[ -n \"\$h\" ]] && echo \"\$h\" || echo \"\$HOME\"
  " 2>/dev/null
}

SERVICE_HOME=$(detect_service_home)
SERVICE_HOME="${SERVICE_HOME%%[[:space:]]}"  # trim whitespace

# Remote paths (absolute, under service user)
REMOTE_AUTH_PROFILES="$SERVICE_HOME/.openclaw/agents/main/agent/auth-profiles.json"
REMOTE_SESSIONS="$SERVICE_HOME/.openclaw/agents/main/sessions/sessions.json"
REMOTE_OAUTH_CREDS="$SERVICE_HOME/.claude/.credentials.json"

# ── Show mode ────────────────────────────────────────────────────────────────

do_show() {
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Auth Status: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  local raw
  raw=$(ssh_exec "$INSTANCE_NAME" "python3 -c \"
import json, pathlib

auth_file = pathlib.Path('$REMOTE_AUTH_PROFILES')
sess_file = pathlib.Path('$REMOTE_SESSIONS')
creds_file = pathlib.Path('$REMOTE_OAUTH_CREDS')

result = {'active_profile': 'unknown', 'order': [], 'oauth_creds': False, 'oauth_expiry': None}

if auth_file.exists():
    data = json.loads(auth_file.read_text())
    result['order'] = data.get('order', {}).get('anthropic', [])
    last_good = data.get('lastGood', {}).get('anthropic', '')
    if last_good:
        result['last_good'] = last_good

if sess_file.exists():
    data = json.loads(sess_file.read_text())
    for key, val in data.items():
        if isinstance(val, dict) and 'authProfileOverride' in val:
            result['active_profile'] = val['authProfileOverride']
            result['override_source'] = val.get('authProfileOverrideSource', '')
            break
    if result['active_profile'] == 'unknown' and result['order']:
        result['active_profile'] = result['order'][0]

if creds_file.exists():
    result['oauth_creds'] = True
    try:
        cdata = json.loads(creds_file.read_text())
        # Unwrap nested claudeAiOauth key if present
        if 'claudeAiOauth' in cdata: cdata = cdata['claudeAiOauth']
        result['oauth_expiry'] = cdata.get('expiresAt', cdata.get('expires_at'))
    except: pass

print(json.dumps(result))
\"" 2>/dev/null) || { log_error "Failed to read auth state"; exit 1; }

  local active order oauth_creds oauth_expiry override_source last_good
  active=$(echo "$raw" | jq -r '.active_profile // "unknown"')
  order=$(echo "$raw" | jq -r '.order | join(" → ")' 2>/dev/null || echo "unknown")
  oauth_creds=$(echo "$raw" | jq -r '.oauth_creds')
  oauth_expiry=$(echo "$raw" | jq -r '.oauth_expiry // "n/a"')
  override_source=$(echo "$raw" | jq -r '.override_source // ""')
  last_good=$(echo "$raw" | jq -r '.last_good // ""')

  local active_color="$YELLOW"
  [[ "$active" == *"oauth"* ]] && active_color="$GREEN"

  printf "  %-22s ${active_color}%s${NC}\n" "Active profile:" "$active"
  [[ -n "$override_source" ]] && printf "  %-22s %s\n" "Override source:" "$override_source"
  printf "  %-22s %s\n"                       "Fallback order:"  "$order"
  [[ -n "$last_good" ]] && printf "  %-22s %s\n" "Last good:" "$last_good"
  printf "  %-22s %s\n"                       "OAuth creds:"     "$oauth_creds"
  printf "  %-22s %s\n"                       "OAuth expiry:"    "$oauth_expiry"
  echo
}

# ── Restart gateway helper ───────────────────────────────────────────────────

restart_gateway() {
  log_info "Restarting gateway..."

  # Try systemd first
  local restarted=false
  if ssh_exec "$INSTANCE_NAME" "sudo systemctl restart openclaw-gateway 2>/dev/null" 2>/dev/null; then
    restarted=true
  fi

  # Fallback: kill then start in separate SSH calls (nohup needs its own session)
  if [[ "$restarted" != "true" ]]; then
    ssh_exec "$INSTANCE_NAME" "pkill -f 'openclaw.*gateway' 2>/dev/null; sleep 1; pkill -9 -f 'openclaw.*gateway' 2>/dev/null || true" 2>/dev/null || true
    sleep 2
    ssh_exec "$INSTANCE_NAME" "nohup openclaw gateway --port 18789 >/tmp/openclaw/gateway.log 2>&1 & echo started-\$!" 2>/dev/null || true
  fi

  sleep 4

  local status
  status=$(ssh_exec "$INSTANCE_NAME" "pgrep -c 'openclaw-gateway' 2>/dev/null || echo 0" 2>/dev/null)
  if [[ "$status" -gt 0 ]] 2>/dev/null; then
    log_success "Gateway restarted"
  else
    log_warn "Gateway not detected — check with: claw logs $INSTANCE_NAME"
  fi
}

# ── Switch to OAuth ──────────────────────────────────────────────────────────

do_oauth() {
  log_info "Switching $INSTANCE_NAME to OAuth..."

  # 1. Verify OAuth credentials exist on remote
  local creds_check
  creds_check=$(ssh_exec "$INSTANCE_NAME" "test -f '$REMOTE_OAUTH_CREDS' && echo exists || echo missing" 2>/dev/null) || creds_check="missing"
  if [[ "$creds_check" != *"exists"* ]]; then
    log_error "OAuth credentials not found on $INSTANCE_NAME"
    echo -e "  Run: ${YELLOW}claw ssh $INSTANCE_NAME${NC} then ${YELLOW}claude login${NC}"
    exit 1
  fi

  # 2. Patch auth-profiles.json + sessions.json
  ssh_exec "$INSTANCE_NAME" "python3 -c \"
import json, pathlib

auth_file = pathlib.Path('$REMOTE_AUTH_PROFILES')
sess_file = pathlib.Path('$REMOTE_SESSIONS')
creds_file = pathlib.Path('$REMOTE_OAUTH_CREDS')

# Read OAuth tokens — unwrap nested claudeAiOauth key if present
creds = json.loads(creds_file.read_text())
if 'claudeAiOauth' in creds: creds = creds['claudeAiOauth']

# Upsert anthropic:oauth profile in auth-profiles.json
auth = json.loads(auth_file.read_text()) if auth_file.exists() else {'version': 1, 'profiles': {}, 'order': {}}
auth['profiles']['anthropic:oauth'] = {
    'type': 'oauth',
    'provider': 'anthropic',
    'accessToken': creds.get('accessToken', creds.get('access_token', '')),
    'refreshToken': creds.get('refreshToken', creds.get('refresh_token', '')),
    'expiresAt': creds.get('expiresAt', creds.get('expires_at', ''))
}
auth.setdefault('order', {})['anthropic'] = ['anthropic:oauth', 'anthropic:token']
# Clear lastGood + usageStats so gateway doesn't auto-override back
auth.pop('lastGood', None)
auth.pop('usageStats', None)
auth_file.write_text(json.dumps(auth, indent=2))

# Patch every session's authProfileOverride
if sess_file.exists():
    sess = json.loads(sess_file.read_text())
    for key, val in sess.items():
        if isinstance(val, dict):
            val['authProfileOverride'] = 'anthropic:oauth'
            val.pop('authProfileOverrideSource', None)
    sess_file.write_text(json.dumps(sess, indent=2))

print('patched')
\"" 2>/dev/null || { log_error "Failed to patch auth files"; exit 1; }

  log_success "Auth files patched → oauth"

  # 3. Restart gateway
  restart_gateway
}

# ── Switch to API key ────────────────────────────────────────────────────────

do_apikey() {
  log_info "Switching $INSTANCE_NAME to API key..."

  ssh_exec "$INSTANCE_NAME" "python3 -c \"
import json, pathlib

auth_file = pathlib.Path('$REMOTE_AUTH_PROFILES')
sess_file = pathlib.Path('$REMOTE_SESSIONS')

# Set order to prefer token
if auth_file.exists():
    auth = json.loads(auth_file.read_text())
    auth.setdefault('order', {})['anthropic'] = ['anthropic:token', 'anthropic:oauth']
    auth.pop('lastGood', None)
    auth.pop('usageStats', None)
    auth_file.write_text(json.dumps(auth, indent=2))

# Patch every session's authProfileOverride
if sess_file.exists():
    sess = json.loads(sess_file.read_text())
    for key, val in sess.items():
        if isinstance(val, dict):
            val['authProfileOverride'] = 'anthropic:token'
            val.pop('authProfileOverrideSource', None)
    sess_file.write_text(json.dumps(sess, indent=2))

print('patched')
\"" 2>/dev/null || { log_error "Failed to patch auth files"; exit 1; }

  log_success "Auth files patched → apikey"

  # Restart gateway
  restart_gateway
}

# ── Main dispatch ────────────────────────────────────────────────────────────

if [[ -z "$MODE" ]]; then
  do_show
else
  case "$MODE" in
    oauth)  do_oauth ;;
    apikey) do_apikey ;;
  esac
fi
