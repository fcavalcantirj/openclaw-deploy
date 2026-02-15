#!/usr/bin/env bash
# =============================================================================
# models.sh — Show/set models and fallbacks on a child instance
# =============================================================================
# Usage:
#   ./scripts/models.sh NAME                       # show model config
#   ./scripts/models.sh NAME --set MODEL           # set default model
#   ./scripts/models.sh NAME --fallbacks '[...]'   # set fallback chain
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [options]

Show or configure the default model and fallbacks on a child instance.

Arguments:
  NAME              Instance name

Options:
  --set MODEL       Set default model (e.g. anthropic/claude-sonnet-4-5-20250929)
  --fallbacks JSON  Set fallback chain as JSON array

Examples:
  $(basename "$0") jack                                             # show model config
  $(basename "$0") jack --set anthropic/claude-opus-4-6             # change default
  $(basename "$0") jack --fallbacks '["anthropic/claude-opus-4-6"]' # set fallbacks

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
SET_MODEL=""
SET_FALLBACKS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --set)
      shift
      [[ $# -lt 1 ]] && { log_error "--set requires a model ID"; usage; }
      SET_MODEL="$1"; shift
      ;;
    --fallbacks)
      shift
      [[ $# -lt 1 ]] && { log_error "--fallbacks requires a JSON array"; usage; }
      SET_FALLBACKS="$1"; shift
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

# ── Detect service home ─────────────────────────────────────────────────────

SERVICE_HOME=$(ssh_exec "$INSTANCE_NAME" "
  for u in openclaw clawdbot \$(whoami); do
    h=\$(getent passwd \"\$u\" 2>/dev/null | cut -d: -f6)
    if [[ -n \"\$h\" && -d \"\$h/.openclaw\" ]]; then echo \"\$h\"; exit 0; fi
  done
  h=\$(find /home -maxdepth 2 -name '.openclaw' -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
  [[ -n \"\$h\" ]] && echo \"\$h\" || echo \"\$HOME\"
" 2>/dev/null)
SERVICE_HOME="${SERVICE_HOME%%[[:space:]]}"

# ── Show mode ────────────────────────────────────────────────────────────────

do_show() {
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Models: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  local raw
  raw=$(ssh_exec "$INSTANCE_NAME" "python3 -c \"
import json, pathlib, subprocess

config_file = pathlib.Path('$SERVICE_HOME/.openclaw/openclaw.json')
result = {'default_model': '', 'fallbacks': [], 'auth_overview': ''}

if config_file.exists():
    cfg = json.loads(config_file.read_text())
    agents = cfg.get('agents', {}).get('defaults', {}).get('model', {})
    result['default_model'] = agents.get('default', '')
    result['fallbacks'] = agents.get('fallbacks', [])

# Try openclaw models for richer output
try:
    out = subprocess.run(['openclaw', 'models'], capture_output=True, text=True, timeout=10)
    result['openclaw_models'] = out.stdout.strip()
except:
    result['openclaw_models'] = ''

print(json.dumps(result))
\"" 2>/dev/null) || { log_error "Failed to read model config"; exit 1; }

  local default_model fallbacks openclaw_models
  default_model=$(echo "$raw" | jq -r '.default_model // "not set"')
  fallbacks=$(echo "$raw" | jq -r '.fallbacks | if length > 0 then join(", ") else "none" end' 2>/dev/null || echo "none")
  openclaw_models=$(echo "$raw" | jq -r '.openclaw_models // ""')

  printf "  %-22s ${GREEN}%s${NC}\n" "Default model:" "$default_model"
  printf "  %-22s %s\n" "Fallbacks:" "$fallbacks"

  if [[ -n "$openclaw_models" ]]; then
    echo
    echo -e "  ${BOLD}openclaw models output:${NC}"
    echo "$openclaw_models" | sed 's/^/    /'
  fi

  echo
}

# ── Set default model ───────────────────────────────────────────────────────

do_set_model() {
  log_info "Setting default model on $INSTANCE_NAME: $SET_MODEL"

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "
    cd $SERVICE_HOME && openclaw models set '$SET_MODEL' 2>&1
  " 2>/dev/null) || { log_error "Failed to set model: $result"; exit 1; }

  log_success "Default model set: $SET_MODEL"
  echo "$result" | sed 's/^/  /'

  restart_gateway
}

# ── Set fallbacks ────────────────────────────────────────────────────────────

do_set_fallbacks() {
  log_info "Setting fallback models on $INSTANCE_NAME"

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "
    cd $SERVICE_HOME && openclaw config set agents.defaults.model.fallbacks '$SET_FALLBACKS' --json 2>&1
  " 2>/dev/null) || { log_error "Failed to set fallbacks: $result"; exit 1; }

  log_success "Fallback models set: $SET_FALLBACKS"

  restart_gateway
}

# ── Restart gateway helper ───────────────────────────────────────────────────

restart_gateway() {
  log_info "Restarting gateway..."

  local restarted=false
  if ssh_exec "$INSTANCE_NAME" "sudo systemctl restart openclaw-gateway 2>/dev/null" 2>/dev/null; then
    restarted=true
  fi

  if [[ "$restarted" != "true" ]]; then
    ssh_exec "$INSTANCE_NAME" "pkill -f 'openclaw.*gateway' 2>/dev/null; sleep 1; pkill -9 -f 'openclaw.*gateway' 2>/dev/null || true" 2>/dev/null || true
    sleep 2
    ssh_exec "$INSTANCE_NAME" "nohup openclaw gateway --port 18789 >/tmp/openclaw/gateway.log 2>&1 & echo started-\$!" 2>/dev/null || true
  fi

  sleep 3
  log_success "Gateway restarted"
}

# ── Main dispatch ────────────────────────────────────────────────────────────

if [[ -n "$SET_MODEL" ]]; then
  do_set_model
fi

if [[ -n "$SET_FALLBACKS" ]]; then
  do_set_fallbacks
fi

if [[ -z "$SET_MODEL" && -z "$SET_FALLBACKS" ]]; then
  do_show
fi
