#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared functions for openclaw-deploy scripts
# =============================================================================
# Source this from any script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/common.sh"
# =============================================================================

# Colors (safe for non-TTY — empty when piped)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ── Logging ─────────────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Prerequisite checks ────────────────────────────────────────────────────
# Usage: require_tools hcloud jq curl ssh-keygen
require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install them before running this script."
    exit 1
  fi
}

# ── Project paths ───────────────────────────────────────────────────────────
# Call resolve_project_root from the sourcing script after setting SCRIPT_DIR
resolve_project_root() {
  # If sourced from scripts/, go up one level
  if [[ "$(basename "$SCRIPT_DIR")" == "scripts" ]]; then
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  else
    PROJECT_ROOT="$SCRIPT_DIR"
  fi
  INSTANCES_DIR="$PROJECT_ROOT/instances"
}

# ── Instance helpers ────────────────────────────────────────────────────────
# Load instance metadata into shell variables
# Usage: load_instance "mybot"
# Sets: INSTANCE_IP, INSTANCE_SSH_KEY, INSTANCE_REGION, INSTANCE_STATUS, etc.
load_instance() {
  local name="$1"
  local meta_file="$INSTANCES_DIR/$name/metadata.json"

  if [[ ! -f "$meta_file" ]]; then
    log_error "Instance '$name' not found (no metadata.json)"
    return 1
  fi

  INSTANCE_IP=$(jq -r '.ip // empty' "$meta_file")
  INSTANCE_SSH_KEY=$(jq -r '.ssh_key_path // .ssh_key // empty' "$meta_file")
  INSTANCE_SSH_USER=$(jq -r '.ssh_user // "root"' "$meta_file")
  INSTANCE_REGION=$(jq -r '.region // "unknown"' "$meta_file")
  INSTANCE_STATUS=$(jq -r '.status // "unknown"' "$meta_file")
  INSTANCE_BOT=$(jq -r '.bot_username // empty' "$meta_file")
  INSTANCE_GATEWAY_TOKEN=$(jq -r '.gateway_token // empty' "$meta_file")
  INSTANCE_META="$meta_file"

  if [[ -z "$INSTANCE_IP" ]]; then
    log_error "Instance '$name' has no IP address in metadata"
    return 1
  fi
}

# ── SSH helpers ─────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Run a command on an instance via SSH
# Usage: ssh_exec "mybot" "systemctl is-active openclaw-gateway"
ssh_exec() {
  local name="$1"
  shift
  load_instance "$name" || return 1

  if [[ ! -f "$INSTANCE_SSH_KEY" ]]; then
    log_error "SSH key not found: $INSTANCE_SSH_KEY"
    return 1
  fi

  ssh -i "$INSTANCE_SSH_KEY" $SSH_OPTS "${INSTANCE_SSH_USER}@${INSTANCE_IP}" "$@"
}

# Check SSH connectivity (returns 0 if reachable)
# Usage: ssh_check "mybot" [timeout_seconds]
ssh_check() {
  local name="$1"
  local timeout="${2:-5}"
  load_instance "$name" || return 1

  if [[ ! -f "$INSTANCE_SSH_KEY" ]]; then
    return 1
  fi

  ssh -i "$INSTANCE_SSH_KEY" $SSH_OPTS -o "ConnectTimeout=$timeout" \
    "${INSTANCE_SSH_USER}@${INSTANCE_IP}" "echo ok" &>/dev/null
}

# ── Metadata helpers ────────────────────────────────────────────────────────
# Update a field in instance metadata
# Usage: update_metadata "mybot" '.status = "operational"'
update_metadata() {
  local name="$1"
  local jq_expr="$2"
  local meta_file="$INSTANCES_DIR/$name/metadata.json"

  if [[ ! -f "$meta_file" ]]; then
    log_error "Metadata not found for '$name'"
    return 1
  fi

  local tmp
  tmp=$(mktemp)
  if jq "$jq_expr" "$meta_file" > "$tmp"; then
    mv "$tmp" "$meta_file"
  else
    rm -f "$tmp"
    log_error "Failed to update metadata for '$name'"
    return 1
  fi
}
