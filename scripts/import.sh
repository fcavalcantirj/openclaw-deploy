#!/usr/bin/env bash
set -euo pipefail

# import.sh - Import an existing server into CLI tracking
# Usage: ./scripts/import.sh <name> <ip> <ssh-key> [--ssh-user USER]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat << EOF
Usage: $0 <name> <ip> <ssh-key> [options]

Import an existing (unmanaged) server so the CLI can track and manage it.

Arguments:
  name        Instance name (alphanumeric + hyphens only)
  ip          Server IP address
  ssh-key     Path to SSH private key for this server

Options:
  --ssh-user USER   SSH user (default: root)
  -h, --help        Show this help message

Examples:
  $0 mybot 1.2.3.4 ~/.ssh/openclaw_mybot
  $0 mybot 1.2.3.4 ~/.ssh/openclaw_mybot --ssh-user ubuntu

What this does:
  1. Validates arguments and checks for duplicates
  2. Creates instances/<name>/metadata.json
  3. Tests SSH connectivity (optional probe)
  4. Reports status

EOF
  exit 1
}

# ── Parse arguments ──────────────────────────────────────────────────────────

if [[ $# -lt 3 ]]; then
  usage
fi

INSTANCE_NAME=""
INSTANCE_IP_ARG=""
SSH_KEY_PATH=""
SSH_USER="root"

# Positional args first
INSTANCE_NAME="$1"; shift
INSTANCE_IP_ARG="$1"; shift
SSH_KEY_PATH="$1"; shift

# Optional flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *)          log_error "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Validate arguments ───────────────────────────────────────────────────────

# Name: alphanumeric + hyphens only
if [[ ! "$INSTANCE_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
  log_error "Invalid instance name: '$INSTANCE_NAME' (alphanumeric + hyphens only, must start with a letter or digit)"
  exit 1
fi

# IP: basic format check (IPv4)
if [[ ! "$INSTANCE_IP_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  log_error "Invalid IP address: '$INSTANCE_IP_ARG' (expected IPv4 format)"
  exit 1
fi

# SSH key: file must exist
SSH_KEY_PATH="$(realpath -m "$SSH_KEY_PATH")"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  log_error "SSH key not found: $SSH_KEY_PATH"
  exit 1
fi

# ── Check for duplicates ─────────────────────────────────────────────────────

INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"

if [[ -f "$INSTANCE_DIR/metadata.json" ]]; then
  log_error "Instance '$INSTANCE_NAME' already tracked at $INSTANCE_DIR"
  log_error "Use 'claw status $INSTANCE_NAME' to view it, or 'claw destroy $INSTANCE_NAME' to remove it first."
  exit 1
fi

# ── Create instance metadata ─────────────────────────────────────────────────

echo
log_info "Importing server as: $INSTANCE_NAME"
log_info "  IP:       $INSTANCE_IP_ARG"
log_info "  SSH key:  $SSH_KEY_PATH"
log_info "  SSH user: $SSH_USER"
echo

mkdir -p "$INSTANCE_DIR"

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$INSTANCE_DIR/metadata.json" << EOF
{
  "name": "$INSTANCE_NAME",
  "ip": "$INSTANCE_IP_ARG",
  "region": "unknown",
  "server_type": "unknown",
  "status": "imported",
  "ssh_user": "$SSH_USER",
  "ssh_key_path": "$SSH_KEY_PATH",
  "created_at": "$CREATED_AT",
  "imported_at": "$CREATED_AT"
}
EOF

log_success "Created $INSTANCE_DIR/metadata.json"

# ── Probe SSH connectivity ───────────────────────────────────────────────────

echo
log_info "Testing SSH connectivity..."

if ssh -i "$SSH_KEY_PATH" $SSH_OPTS -o "ConnectTimeout=5" \
  "${SSH_USER}@${INSTANCE_IP_ARG}" "echo ok" &>/dev/null; then
  log_success "SSH connection successful"

  # Probe gateway status
  log_info "Checking for OpenClaw gateway..."
  GW_STATUS=$(ssh -i "$SSH_KEY_PATH" $SSH_OPTS \
    "${SSH_USER}@${INSTANCE_IP_ARG}" \
    "systemctl is-active openclaw-gateway 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "unknown")

  if [[ "$GW_STATUS" == "active" ]]; then
    log_success "Gateway is running"
    update_metadata "$INSTANCE_NAME" '.status = "operational"'
  else
    log_warn "Gateway status: $GW_STATUS"
  fi
else
  log_warn "Could not connect via SSH (server may be offline or key may not be authorized)"
  log_warn "Instance imported anyway — retry with: claw status $INSTANCE_NAME"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
log_success "Import complete: $INSTANCE_NAME"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo
echo "Next steps:"
echo "  View details:        claw status $INSTANCE_NAME"
echo "  List all instances:  claw list"
echo "  SSH to server:       claw ssh $INSTANCE_NAME"
echo
