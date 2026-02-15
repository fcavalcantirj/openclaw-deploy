#!/usr/bin/env bash
# =============================================================================
# plugins.sh — Show/enable/disable OpenClaw plugins on a child instance
# =============================================================================
# Usage:
#   ./scripts/plugins.sh NAME                     # show plugin status
#   ./scripts/plugins.sh NAME --enable PLUGIN_ID  # enable a plugin
#   ./scripts/plugins.sh NAME --disable PLUGIN_ID # disable a plugin
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [options]

Show, enable, or disable OpenClaw plugins on a child instance.

Arguments:
  NAME                Instance name

Options:
  --enable PLUGIN_ID  Enable a plugin (e.g. google-gemini-cli-auth)
  --disable PLUGIN_ID Disable a plugin
  --list              Show all plugins (default)

Examples:
  $(basename "$0") jack                                 # list plugins
  $(basename "$0") jack --enable google-gemini-cli-auth # enable plugin
  $(basename "$0") jack --disable copilot-proxy         # disable plugin

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
ENABLE_PLUGIN=""
DISABLE_PLUGIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable)
      shift
      [[ $# -lt 1 ]] && { log_error "--enable requires a plugin ID"; usage; }
      ENABLE_PLUGIN="$1"; shift
      ;;
    --disable)
      shift
      [[ $# -lt 1 ]] && { log_error "--disable requires a plugin ID"; usage; }
      DISABLE_PLUGIN="$1"; shift
      ;;
    --list) shift ;;
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

# ── Show plugins ─────────────────────────────────────────────────────────────

do_show() {
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Plugins: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  local raw
  raw=$(ssh_exec "$INSTANCE_NAME" "openclaw plugins list 2>&1" 2>/dev/null) || raw="(failed to list plugins)"

  echo "$raw" | sed 's/^/  /'
  echo
}

# ── Enable plugin ────────────────────────────────────────────────────────────

do_enable() {
  log_info "Enabling plugin on $INSTANCE_NAME: $ENABLE_PLUGIN"

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "
    openclaw config set plugins.entries.${ENABLE_PLUGIN}.enabled true 2>&1
  " 2>/dev/null) || { log_error "Failed to enable plugin: $result"; exit 1; }

  log_success "Plugin enabled: $ENABLE_PLUGIN"

  restart_gateway
}

# ── Disable plugin ───────────────────────────────────────────────────────────

do_disable() {
  log_info "Disabling plugin on $INSTANCE_NAME: $DISABLE_PLUGIN"

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "
    openclaw config set plugins.entries.${DISABLE_PLUGIN}.enabled false 2>&1
  " 2>/dev/null) || { log_error "Failed to disable plugin: $result"; exit 1; }

  log_success "Plugin disabled: $DISABLE_PLUGIN"

  restart_gateway
}

# ── Main dispatch ────────────────────────────────────────────────────────────

if [[ -n "$ENABLE_PLUGIN" ]]; then
  do_enable
elif [[ -n "$DISABLE_PLUGIN" ]]; then
  do_disable
else
  do_show
fi
