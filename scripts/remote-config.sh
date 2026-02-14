#!/usr/bin/env bash
# =============================================================================
# remote-config.sh — View/set AMCP config on a child instance
# =============================================================================
# Usage:
#   ./scripts/remote-config.sh NAME              # default: --show
#   ./scripts/remote-config.sh NAME --show       # display config (secrets masked)
#   ./scripts/remote-config.sh NAME --set key=value
#   ./scripts/remote-config.sh NAME --push       # bulk push from credentials.json
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [--show|--set key=value|--push]

Manage AMCP config (~/.amcp/config.json) on a child instance.

Arguments:
  NAME    Instance name

Options:
  --show          Display config with secrets masked (default)
  --set key=val   Set a single config key
  --push          Bulk push keys from local credentials.json

Examples:
  $(basename "$0") jack --show
  $(basename "$0") jack --set pinata_jwt=eyJ...
  $(basename "$0") jack --push

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
ACTION="show"
SET_KEY=""
SET_VAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --show)    ACTION="show"; shift ;;
    --set)
      ACTION="set"
      shift
      [[ $# -lt 1 ]] && { log_error "--set requires key=value"; usage; }
      SET_KEY="${1%%=*}"
      SET_VAL="${1#*=}"
      if [[ "$SET_KEY" == "$1" ]]; then
        log_error "Invalid format: use --set key=value"; usage
      fi
      shift
      ;;
    --push)    ACTION="push"; shift ;;
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

# ── Load instance ────────────────────────────────────────────────────────────

load_instance "$INSTANCE_NAME" || exit 1

# Verify SSH connectivity
if ! ssh_check "$INSTANCE_NAME" 10 2>/dev/null; then
  log_error "Cannot reach $INSTANCE_NAME via SSH"
  exit 1
fi

# ── Mask helper ──────────────────────────────────────────────────────────────

mask_secret() {
  local val="$1"
  if [[ ${#val} -le 4 || "$val" == "null" || -z "$val" ]]; then
    echo "$val"
  else
    echo "${val:0:4}***"
  fi
}

# ── Action: show ─────────────────────────────────────────────────────────────

do_show() {
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  AMCP Config: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  # Known config keys to check (flat + dot-path)
  local keys=(
    pinata_jwt
    anthropic.apiKey
    solvr_api_key
    instance_name
    parent_bot_token
    parent_chat_id
    notify.emailTo
    notify.agentmailApiKey
    notify.agentmailInbox
    watchdog.interval
    checkpoint.schedule
  )

  # Fetch all values in a single SSH call
  local key_list=""
  for k in "${keys[@]}"; do
    key_list+="$k "
  done

  local raw
  raw=$(ssh_exec "$INSTANCE_NAME" "bash -c '
    for key in $key_list; do
      val=\$(proactive-amcp config get \"\$key\" 2>/dev/null || echo \"\")
      echo \"CFG:\${key}=\${val}\"
    done
  '" 2>/dev/null) || true

  # Secret keys that should be masked
  local secret_keys="pinata_jwt anthropic.apiKey solvr_api_key parent_bot_token notify.agentmailApiKey"

  while IFS= read -r line; do
    [[ "$line" != CFG:* ]] && continue
    local kv="${line#CFG:}"
    local key="${kv%%=*}"
    local val="${kv#*=}"

    # Mask secrets
    if echo "$secret_keys" | grep -qw "$key"; then
      val=$(mask_secret "$val")
    fi

    printf "  %-26s %s\n" "$key:" "$val"
  done <<< "$raw"

  echo
}

# ── Action: set ──────────────────────────────────────────────────────────────

do_set() {
  log_info "Setting $SET_KEY on $INSTANCE_NAME..."

  local escaped_key escaped_val
  escaped_key=$(printf '%q' "$SET_KEY")
  escaped_val=$(printf '%q' "$SET_VAL")

  ssh_exec "$INSTANCE_NAME" \
    "proactive-amcp config set $escaped_key $escaped_val" 2>/dev/null

  # Verify by reading back
  local readback
  readback=$(ssh_exec "$INSTANCE_NAME" \
    "proactive-amcp config get $escaped_key 2>/dev/null" 2>/dev/null) || true

  if [[ "$readback" == "$SET_VAL" ]]; then
    log_success "$SET_KEY set and verified"
  else
    log_warn "$SET_KEY set but readback differs (may be OK for nested paths)"
  fi
}

# ── Action: push ─────────────────────────────────────────────────────────────

do_push() {
  local credentials_file="$INSTANCES_DIR/credentials.json"
  if [[ ! -f "$credentials_file" ]]; then
    log_error "credentials.json not found at $credentials_file"
    exit 1
  fi

  echo -e "${BLUE}Pushing config from credentials.json to $INSTANCE_NAME...${NC}"

  # Key mapping: credentials.json key -> AMCP config key
  # Format: "source_key:dest_key"
  local mappings=(
    "pinata_jwt:pinata_jwt"
    "anthropic_api_key:anthropic.apiKey"
    "solvr_api_key:solvr_api_key"
    "parent_telegram_bot_token:parent_bot_token"
    "parent_telegram_chat_id:parent_chat_id"
    "agentmail_api_key:notify.agentmailApiKey"
    "notify_email:notify.emailTo"
  )

  local pushed=0
  local skipped=0

  for mapping in "${mappings[@]}"; do
    local src_key="${mapping%%:*}"
    local dst_key="${mapping#*:}"

    local val
    val=$(jq -r ".${src_key} // empty" "$credentials_file")

    if [[ -z "$val" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    local escaped_dst escaped_val
    escaped_dst=$(printf '%q' "$dst_key")
    escaped_val=$(printf '%q' "$val")

    ssh_exec "$INSTANCE_NAME" \
      "proactive-amcp config set $escaped_dst $escaped_val" 2>/dev/null && {
      log_success "$dst_key"
      pushed=$((pushed + 1))
    } || {
      log_error "Failed: $dst_key"
    }
  done

  # Also push instance_name from metadata
  local instance_name
  instance_name=$(jq -r '.name // empty' "$INSTANCE_META" 2>/dev/null)
  if [[ -n "$instance_name" ]]; then
    local escaped_name
    escaped_name=$(printf '%q' "$instance_name")
    ssh_exec "$INSTANCE_NAME" \
      "proactive-amcp config set instance_name $escaped_name" 2>/dev/null && {
      log_success "instance_name"
      pushed=$((pushed + 1))
    }
  fi

  echo
  log_info "$pushed keys pushed, $skipped skipped (empty in credentials.json)"
}

# ── Main dispatch ────────────────────────────────────────────────────────────

case "$ACTION" in
  show) do_show ;;
  set)  do_set ;;
  push) do_push ;;
esac
