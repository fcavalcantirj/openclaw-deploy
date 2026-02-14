#!/usr/bin/env bash
# =============================================================================
# diagnose-remote.sh — Enhanced health diagnostics for child instances
# =============================================================================
# Usage: ./scripts/diagnose-remote.sh NAME|self [--json]
#
# Two-layer architecture:
#   Layer 1: Parent-side checks (SSH connectivity, metadata)
#   Layer 2: Child-side checks (single SSH batch — 14 checks total)
#
# Output: human-readable colored report (default) or --json for machine use.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME|self [--json]

Run comprehensive health diagnostics on a child instance or locally.

Arguments:
  NAME    Instance name to diagnose remotely (14 checks)
  self    Run proactive-amcp diagnose locally

Options:
  --json  Machine-consumable JSON output

Checks performed:
  1. SSH connectivity        8. Claude Code CLI
  2. Gateway process         9. Claude Code auth (OAuth)
  3. Health endpoint        10. Anthropic API key
  4. Session corruption     11. User mismatch detection
  5. Config JSON validity   12. AMCP identity
  6. Disk space             13. AMCP config completeness
  7. Memory                 14. Last checkpoint age

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)    OUTPUT_JSON=true; shift ;;
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

# ── Self-diagnosis (local) ───────────────────────────────────────────────────

if [[ "$INSTANCE_NAME" == "self" ]]; then
  echo -e "${BLUE}Running local self-diagnosis...${NC}" >&2
  proactive-amcp diagnose --json
  exit $?
fi

# ── Load instance ────────────────────────────────────────────────────────────

load_instance "$INSTANCE_NAME" || exit 1

# ── Result tracking ──────────────────────────────────────────────────────────

declare -A CHECK_STATUS  # ok, warn, error
declare -A CHECK_DETAIL
PASS=0; WARN=0; FAIL=0

record() {
  local name="$1" status="$2" detail="$3"
  CHECK_STATUS[$name]="$status"
  CHECK_DETAIL[$name]="$detail"
  case "$status" in
    ok)    PASS=$((PASS + 1)) ;;
    warn)  WARN=$((WARN + 1)) ;;
    error) FAIL=$((FAIL + 1)) ;;
  esac
}

# Status indicator for human output
indicator() {
  case "$1" in
    ok)    echo -e "${GREEN}[OK]${NC}" ;;
    warn)  echo -e "${YELLOW}[WARN]${NC}" ;;
    error) echo -e "${RED}[FAIL]${NC}" ;;
  esac
}

# ── Layer 1: Parent-side checks ─────────────────────────────────────────────

# Check 1: SSH connectivity
ssh_start=$(date +%s%N 2>/dev/null || date +%s)
if ssh -i "$INSTANCE_SSH_KEY" $SSH_OPTS -o "ConnectTimeout=10" \
    "${INSTANCE_SSH_USER}@$INSTANCE_IP" "echo ok" &>/dev/null; then
  ssh_end=$(date +%s%N 2>/dev/null || date +%s)
  if [[ ${#ssh_start} -gt 10 ]]; then
    ssh_ms=$(( (ssh_end - ssh_start) / 1000000 ))
  else
    ssh_ms=$(( (ssh_end - ssh_start) * 1000 ))
  fi
  record "ssh" "ok" "Connected (${INSTANCE_SSH_USER}, ${ssh_ms}ms)"
else
  record "ssh" "error" "Cannot reach ${INSTANCE_IP}"
  # Cannot proceed without SSH
  if [[ "$OUTPUT_JSON" == true ]]; then
    jq -n \
      --arg instance "$INSTANCE_NAME" \
      --arg ip "$INSTANCE_IP" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        instance: $instance,
        ip: $ip,
        timestamp: $timestamp,
        checks_passed: 0,
        checks_failed: 1,
        checks_warned: 0,
        checks: { ssh: { status: "error", detail: "Cannot reach instance via SSH" } },
        errors: ["SSH unreachable"]
      }'
  else
    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Diagnosing: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
    echo
    echo -e "Connectivity:"
    echo -e "  SSH:                  $(indicator error) Cannot reach ${INSTANCE_IP}"
    echo
    echo -e "Summary: 0 passed, 0 warnings, ${RED}1 error${NC}"
  fi
  exit 1
fi

# ── Layer 2: Child-side checks (single SSH batch) ───────────────────────────
# Collects all data in one SSH call, then parses locally.

PROBE=$(ssh -i "$INSTANCE_SSH_KEY" $SSH_OPTS "${INSTANCE_SSH_USER}@$INSTANCE_IP" "bash -s" <<'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -uo pipefail

# Separator for parsing
SEP="---CLAW_CHECK---"

# ── Gateway process ──────────────────────────────────────────────────────
echo "${SEP}gateway_process"
if pgrep -f "openclaw-gateway\|openclaw.*gateway" >/dev/null 2>&1; then
  PORT=$(ss -tlnp 2>/dev/null | grep -oP '(?<=:)(18789|3141|8080)(?=\s)' | head -1)
  echo "ok:${PORT:-unknown}"
else
  echo "error:not_running"
fi

# ── Health endpoint ──────────────────────────────────────────────────────
echo "${SEP}health_endpoint"
HEALTH_PORTS="18789 3141 8080"
HEALTH_OK=false
for p in $HEALTH_PORTS; do
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:${p}/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    RESP_TIME=$(curl -s -o /dev/null -w '%{time_total}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:${p}/health" 2>/dev/null || echo "0")
    RESP_MS=$(echo "$RESP_TIME" | awk '{printf "%.0f", $1 * 1000}')
    echo "ok:port=${p}:${RESP_MS}ms"
    HEALTH_OK=true
    break
  fi
done
if [[ "$HEALTH_OK" != true ]]; then
  echo "error:no_health_endpoint"
fi

# ── Session corruption ───────────────────────────────────────────────────
echo "${SEP}sessions"
SESSION_DIR="${HOME}/.openclaw/agents/main/sessions"
if [[ -d "$SESSION_DIR" ]]; then
  CORRUPT=0
  TOTAL=0
  for f in "$SESSION_DIR"/*.jsonl 2>/dev/null; do
    [[ -f "$f" ]] || continue
    TOTAL=$((TOTAL + 1))
    # Check last 5 lines for valid JSON
    if ! tail -5 "$f" 2>/dev/null | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      echo "$line" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null || exit 1
    done; then
      CORRUPT=$((CORRUPT + 1))
    fi
  done
  if [[ $CORRUPT -gt 0 ]]; then
    echo "warn:${CORRUPT}/${TOTAL}_corrupt"
  else
    echo "ok:${TOTAL}_sessions"
  fi
else
  echo "ok:no_sessions_dir"
fi

# ── Config JSON validity ────────────────────────────────────────────────
echo "${SEP}config_valid"
AMCP_CONFIG="${HOME}/.amcp/config.json"
if [[ -f "$AMCP_CONFIG" ]]; then
  if python3 -c "import json; json.load(open('${AMCP_CONFIG}'))" 2>/dev/null; then
    echo "ok:valid"
  else
    echo "error:invalid_json"
  fi
else
  echo "warn:no_config"
fi

# ── Disk space ───────────────────────────────────────────────────────────
echo "${SEP}disk"
DISK_PCT=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
DISK_FREE=$((100 - ${DISK_PCT:-0}))
echo "${DISK_FREE}"

# ── Memory ───────────────────────────────────────────────────────────────
echo "${SEP}memory"
MEM_PCT=$(free 2>/dev/null | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
MEM_AVAIL=$((100 - ${MEM_PCT:-0}))
echo "${MEM_AVAIL}:${MEM_PCT:-unknown}"

# ── Claude Code CLI ──────────────────────────────────────────────────────
echo "${SEP}claude_cli"
if command -v claude &>/dev/null; then
  VER=$(claude --version 2>/dev/null | head -1 || echo "installed")
  echo "ok:${VER}"
else
  echo "warn:not_installed"
fi

# ── Claude Code auth (OAuth) ────────────────────────────────────────────
echo "${SEP}claude_auth"
# Detect service user
SVC_USER=""
SVC_USER=$(systemctl show -p User openclaw-gateway 2>/dev/null | cut -d= -f2)
[[ -z "$SVC_USER" ]] && SVC_USER=$(ps -eo user,comm 2>/dev/null | grep -i "openclaw\|gateway" | awk '{print $1}' | head -1)
[[ -z "$SVC_USER" ]] && SVC_USER="root"

# Check credentials file for the service user
if [[ "$SVC_USER" == "root" ]]; then
  CRED_PATH="/root/.claude/.credentials.json"
else
  CRED_PATH="/home/${SVC_USER}/.claude/.credentials.json"
fi

if [[ -f "$CRED_PATH" ]]; then
  # Verify OAuth works with a quick test (timeout 15s)
  CLAUDE_TEST=$(timeout 15 su - "$SVC_USER" -s /bin/bash -c "claude --print 'respond with just: ok' 2>&1 | head -5" 2>/dev/null || echo "TIMEOUT_OR_ERROR")
  if echo "$CLAUDE_TEST" | grep -qi "ok"; then
    echo "ok:active:${SVC_USER}"
  elif echo "$CLAUDE_TEST" | grep -qi "error\|expired\|unauthorized\|TIMEOUT"; then
    echo "warn:expired:${SVC_USER}"
  else
    echo "warn:unknown:${SVC_USER}:$(echo "$CLAUDE_TEST" | head -1)"
  fi
else
  echo "warn:no_credentials:${SVC_USER}"
fi

# ── Anthropic API key ───────────────────────────────────────────────────
echo "${SEP}api_key"
# Try to get key from AMCP config first, then auth-profiles
API_KEY=""
if command -v proactive-amcp &>/dev/null; then
  API_KEY=$(proactive-amcp config get anthropic.apiKey 2>/dev/null || echo "")
fi
if [[ -z "$API_KEY" || "$API_KEY" == "null" ]]; then
  AUTH_PROFILE="${HOME}/.openclaw/agents/main/agent/auth-profiles.json"
  if [[ -f "$AUTH_PROFILE" ]]; then
    API_KEY=$(python3 -c "
import json
with open('${AUTH_PROFILE}') as f:
  data = json.load(f)
for p in data if isinstance(data, list) else [data]:
  k = p.get('apiKey', p.get('api_key', ''))
  if k: print(k); break
" 2>/dev/null || echo "")
  fi
fi

if [[ -n "$API_KEY" && "$API_KEY" != "null" ]]; then
  # Test the key with a minimal request
  HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "x-api-key: ${API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"ok"}]}' \
    --connect-timeout 5 --max-time 10 \
    "https://api.anthropic.com/v1/messages" 2>/dev/null || echo "000")
  KEY_PREFIX="${API_KEY:0:10}***"
  echo "${HTTP_STATUS}:${KEY_PREFIX}"
else
  echo "missing:"
fi

# ── User mismatch ───────────────────────────────────────────────────────
echo "${SEP}user_mismatch"
# Service user already detected above
CURR_USER=$(whoami)
echo "${CURR_USER}:${SVC_USER}"

# ── AMCP identity ───────────────────────────────────────────────────────
echo "${SEP}amcp_identity"
IDENTITY_FILE="${HOME}/.amcp/identity.json"
if [[ -f "$IDENTITY_FILE" ]]; then
  AID=$(python3 -c "import json; print(json.load(open('${IDENTITY_FILE}')).get('aid',''))" 2>/dev/null || echo "")
  if [[ -n "$AID" && "$AID" == B* ]]; then
    # Validate if amcp CLI available
    if command -v amcp &>/dev/null; then
      if amcp identity validate --path "$IDENTITY_FILE" &>/dev/null; then
        echo "ok:${AID}"
      else
        echo "error:invalid:${AID}"
      fi
    else
      echo "ok:${AID}:no_cli_validation"
    fi
  elif [[ -n "$AID" ]]; then
    echo "error:fake:${AID}"
  else
    echo "error:no_aid"
  fi
else
  echo "error:no_identity"
fi

# ── AMCP config completeness ────────────────────────────────────────────
echo "${SEP}amcp_config"
if command -v proactive-amcp &>/dev/null && [[ -f "${HOME}/.amcp/config.json" ]]; then
  MISSING=""
  for key in pinata_jwt solvr_api_key instance_name; do
    VAL=$(proactive-amcp config get "$key" 2>/dev/null || echo "")
    if [[ -z "$VAL" || "$VAL" == "null" ]]; then
      MISSING="${MISSING}${key},"
    fi
  done
  # Also check anthropic.apiKey (dot-path)
  VAL=$(proactive-amcp config get "anthropic.apiKey" 2>/dev/null || echo "")
  if [[ -z "$VAL" || "$VAL" == "null" ]]; then
    MISSING="${MISSING}anthropic.apiKey,"
  fi
  MISSING="${MISSING%,}"
  if [[ -z "$MISSING" ]]; then
    echo "ok:all_present"
  else
    echo "warn:missing:${MISSING}"
  fi
else
  echo "warn:no_pamcp_or_config"
fi

# ── Last checkpoint ──────────────────────────────────────────────────────
echo "${SEP}last_checkpoint"
CKPT_FILE="${HOME}/.amcp/last-checkpoint.json"
if [[ -f "$CKPT_FILE" ]]; then
  CKPT_DATA=$(python3 -c "
import json, time
with open('${CKPT_FILE}') as f:
  data = json.load(f)
cid = data.get('cid', data.get('localPath', 'unknown'))
ts = data.get('timestamp', '')
if ts:
  import datetime
  try:
    dt = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00'))
    age_s = time.time() - dt.timestamp()
    hours = int(age_s / 3600)
    print(f'{cid}:{hours}h')
  except:
    print(f'{cid}:unknown_age')
else:
  print(f'{cid}:no_timestamp')
" 2>/dev/null || echo "error:parse_failed")
  echo "$CKPT_DATA"
else
  echo "none:"
fi
REMOTE_SCRIPT
) 2>/dev/null || true

# ── Parse remote probe results ──────────────────────────────────────────────

parse_field() {
  echo "$PROBE" | sed -n "/^---CLAW_CHECK---${1}$/,/^---CLAW_CHECK---/{ /^---CLAW_CHECK---/d; p; }" | head -1
}

# Check 2: Gateway process
gw=$(parse_field "gateway_process")
case "$gw" in
  ok:*)    record "gateway" "ok" "Port ${gw#ok:}" ;;
  *)       record "gateway" "error" "Not running" ;;
esac

# Check 3: Health endpoint
health=$(parse_field "health_endpoint")
case "$health" in
  ok:*)    record "health" "ok" "${health#ok:}" ;;
  *)       record "health" "error" "No health endpoint responding" ;;
esac

# Check 4: Session corruption
sessions=$(parse_field "sessions")
case "$sessions" in
  ok:*)    record "sessions" "ok" "${sessions#ok:}" ;;
  warn:*)  record "sessions" "warn" "${sessions#warn:}" ;;
  *)       record "sessions" "error" "Check failed" ;;
esac

# Check 5: Config JSON validity
cfg_valid=$(parse_field "config_valid")
case "$cfg_valid" in
  ok:*)    record "config_json" "ok" "Valid JSON" ;;
  warn:*)  record "config_json" "warn" "No config file" ;;
  *)       record "config_json" "error" "Invalid JSON" ;;
esac

# Check 6: Disk space
disk_free=$(parse_field "disk")
disk_free="${disk_free:-0}"
[[ "$disk_free" =~ ^[0-9]+$ ]] || disk_free=0
if [[ "$disk_free" -gt 50 ]]; then
  record "disk" "ok" "${disk_free}% free"
elif [[ "$disk_free" -gt 20 ]]; then
  record "disk" "warn" "${disk_free}% free"
else
  record "disk" "error" "${disk_free}% free (critical)"
fi

# Check 7: Memory
mem_raw=$(parse_field "memory")
mem_avail="${mem_raw%%:*}"
mem_used="${mem_raw##*:}"
mem_avail="${mem_avail:-0}"
[[ "$mem_avail" =~ ^[0-9]+$ ]] || mem_avail=0
if [[ "$mem_avail" -gt 20 ]]; then
  record "memory" "ok" "${mem_avail}% available"
elif [[ "$mem_avail" -gt 10 ]]; then
  record "memory" "warn" "${mem_avail}% available"
else
  record "memory" "error" "${mem_avail}% available (critical)"
fi

# Check 7b: Claude Code CLI
claude_cli=$(parse_field "claude_cli")
case "$claude_cli" in
  ok:*)    record "claude_cli" "ok" "Installed (${claude_cli#ok:})" ;;
  *)       record "claude_cli" "warn" "Not installed" ;;
esac

# Check 8: Claude Code auth (OAuth)
claude_auth=$(parse_field "claude_auth")
case "$claude_auth" in
  ok:active:*)  record "claude_auth" "ok" "OAuth active (${claude_auth##*:} user)" ;;
  warn:expired:*) record "claude_auth" "warn" "OAuth expired (${claude_auth##*:} user)" ;;
  warn:no_credentials:*) record "claude_auth" "warn" "No credentials (${claude_auth##*:} user)" ;;
  *)            record "claude_auth" "warn" "${claude_auth}" ;;
esac

# Check 9: Anthropic API key
api_key_raw=$(parse_field "api_key")
api_status="${api_key_raw%%:*}"
api_detail="${api_key_raw#*:}"
case "$api_status" in
  200)     record "api_key" "ok" "Valid ($api_detail)" ;;
  401)     record "api_key" "error" "Invalid key ($api_detail)" ;;
  402)     record "api_key" "error" "No credits ($api_detail)" ;;
  429)     record "api_key" "warn" "Rate limited ($api_detail)" ;;
  missing) record "api_key" "error" "No API key found" ;;
  *)       record "api_key" "warn" "HTTP $api_status ($api_detail)" ;;
esac

# Check 10: User mismatch
user_raw=$(parse_field "user_mismatch")
ssh_user="${user_raw%%:*}"
svc_user="${user_raw##*:}"
if [[ "$ssh_user" == "$svc_user" || -z "$svc_user" ]]; then
  record "user_mismatch" "ok" "SSH=$ssh_user, Service=$svc_user"
else
  record "user_mismatch" "warn" "SSH=$ssh_user but service runs as $svc_user"
fi

# Check 11: AMCP identity
amcp_id=$(parse_field "amcp_identity")
case "$amcp_id" in
  ok:B*)
    aid="${amcp_id#ok:}"
    aid_short="${aid:0:8}..."
    record "amcp_identity" "ok" "${aid_short} (valid KERI)"
    ;;
  error:fake:*)   record "amcp_identity" "error" "Fake identity (${amcp_id##*:})" ;;
  error:invalid:*) record "amcp_identity" "error" "Invalid identity" ;;
  error:no_identity) record "amcp_identity" "error" "No identity file" ;;
  *)              record "amcp_identity" "error" "Identity check failed" ;;
esac

# Check 12: AMCP config completeness
amcp_cfg=$(parse_field "amcp_config")
case "$amcp_cfg" in
  ok:*)           record "amcp_config" "ok" "All keys present" ;;
  warn:missing:*) record "amcp_config" "warn" "Missing: ${amcp_cfg#warn:missing:}" ;;
  *)              record "amcp_config" "warn" "Cannot check (no proactive-amcp or config)" ;;
esac

# Check 13: Last checkpoint
ckpt=$(parse_field "last_checkpoint")
case "$ckpt" in
  none:*)
    record "checkpoint" "warn" "No checkpoint found"
    ;;
  error:*)
    record "checkpoint" "warn" "Cannot read checkpoint file"
    ;;
  *)
    ckpt_cid="${ckpt%%:*}"
    ckpt_age="${ckpt#*:}"
    ckpt_cid_short="${ckpt_cid:0:12}..."
    # Parse hours for age assessment
    age_h="${ckpt_age%h}"
    if [[ "$age_h" =~ ^[0-9]+$ ]] && [[ "$age_h" -gt 24 ]]; then
      record "checkpoint" "warn" "$ckpt_cid_short (${ckpt_age} — stale)"
    else
      record "checkpoint" "ok" "$ckpt_cid_short (${ckpt_age})"
    fi
    ;;
esac

# ── Output ───────────────────────────────────────────────────────────────────

if [[ "$OUTPUT_JSON" == true ]]; then
  # Build JSON output (backward compatible with claw fix expectations)
  checks_json="{"
  for name in ssh gateway health sessions config_json disk memory claude_cli claude_auth api_key user_mismatch amcp_identity amcp_config checkpoint; do
    status="${CHECK_STATUS[$name]:-unknown}"
    detail="${CHECK_DETAIL[$name]:-}"
    # Escape for JSON
    detail="${detail//\\/\\\\}"
    detail="${detail//\"/\\\"}"
    checks_json+="\"$name\":{\"status\":\"$status\",\"detail\":\"$detail\"},"
  done
  checks_json="${checks_json%,}}"

  # Build errors array
  errors="["
  for name in "${!CHECK_STATUS[@]}"; do
    if [[ "${CHECK_STATUS[$name]}" == "error" ]]; then
      detail="${CHECK_DETAIL[$name]:-}"
      detail="${detail//\\/\\\\}"
      detail="${detail//\"/\\\"}"
      errors+="\"${name}: ${detail}\","
    fi
  done
  errors="${errors%,}]"

  jq -n \
    --arg instance "$INSTANCE_NAME" \
    --arg ip "$INSTANCE_IP" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson checks_passed "$PASS" \
    --argjson checks_failed "$FAIL" \
    --argjson checks_warned "$WARN" \
    --argjson checks "$checks_json" \
    --argjson errors "$errors" \
    '{
      instance: $instance,
      ip: $ip,
      timestamp: $timestamp,
      checks_passed: $checks_passed,
      checks_failed: $checks_failed,
      checks_warned: $checks_warned,
      checks: $checks,
      errors: $errors
    }'
else
  # Human-readable colored report
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Diagnosing: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  echo "Connectivity:"
  printf "  %-22s %s %s\n" "SSH:" "$(indicator "${CHECK_STATUS[ssh]}")" "${CHECK_DETAIL[ssh]}"
  printf "  %-22s %s %s\n" "Gateway:" "$(indicator "${CHECK_STATUS[gateway]}")" "${CHECK_DETAIL[gateway]}"
  printf "  %-22s %s %s\n" "Health Endpoint:" "$(indicator "${CHECK_STATUS[health]}")" "${CHECK_DETAIL[health]}"
  echo

  echo "Authentication:"
  printf "  %-22s %s %s\n" "Anthropic API Key:" "$(indicator "${CHECK_STATUS[api_key]}")" "${CHECK_DETAIL[api_key]}"
  printf "  %-22s %s %s\n" "Claude Code CLI:" "$(indicator "${CHECK_STATUS[claude_cli]}")" "${CHECK_DETAIL[claude_cli]}"
  printf "  %-22s %s %s\n" "Claude Code Auth:" "$(indicator "${CHECK_STATUS[claude_auth]}")" "${CHECK_DETAIL[claude_auth]}"
  printf "  %-22s %s %s\n" "User Mismatch:" "$(indicator "${CHECK_STATUS[user_mismatch]}")" "${CHECK_DETAIL[user_mismatch]}"
  echo

  echo "AMCP:"
  printf "  %-22s %s %s\n" "Identity:" "$(indicator "${CHECK_STATUS[amcp_identity]}")" "${CHECK_DETAIL[amcp_identity]}"
  printf "  %-22s %s %s\n" "Config:" "$(indicator "${CHECK_STATUS[amcp_config]}")" "${CHECK_DETAIL[amcp_config]}"
  printf "  %-22s %s %s\n" "Last Checkpoint:" "$(indicator "${CHECK_STATUS[checkpoint]}")" "${CHECK_DETAIL[checkpoint]}"
  echo

  echo "System:"
  printf "  %-22s %s %s\n" "Disk:" "$(indicator "${CHECK_STATUS[disk]}")" "${CHECK_DETAIL[disk]}"
  printf "  %-22s %s %s\n" "Memory:" "$(indicator "${CHECK_STATUS[memory]}")" "${CHECK_DETAIL[memory]}"
  printf "  %-22s %s %s\n" "Config JSON:" "$(indicator "${CHECK_STATUS[config_json]}")" "${CHECK_DETAIL[config_json]}"
  printf "  %-22s %s %s\n" "Sessions:" "$(indicator "${CHECK_STATUS[sessions]}")" "${CHECK_DETAIL[sessions]}"
  echo

  # Summary line
  summary="$PASS passed"
  [[ $WARN -gt 0 ]] && summary+=", ${YELLOW}$WARN warnings${NC}"
  [[ $FAIL -gt 0 ]] && summary+=", ${RED}$FAIL errors${NC}"
  [[ $WARN -eq 0 && $FAIL -eq 0 ]] && summary+=", 0 warnings, 0 errors"
  echo -e "Summary: $summary"
  echo
fi
