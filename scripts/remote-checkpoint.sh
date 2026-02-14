#!/usr/bin/env bash
# =============================================================================
# remote-checkpoint.sh — Trigger an AMCP checkpoint on a child instance
# =============================================================================
# Usage: ./scripts/remote-checkpoint.sh NAME [--full]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [--full]

Run an AMCP checkpoint on a child instance.

Arguments:
  NAME    Instance name

Options:
  --full  Full checkpoint with secrets (default: quick checkpoint)

Examples:
  $(basename "$0") jack          # Quick checkpoint
  $(basename "$0") jack --full   # Full checkpoint with secrets

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
FULL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)    FULL=true; shift ;;
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
log_info "Connecting to $INSTANCE_NAME ($INSTANCE_IP)..."
if ! ssh_check "$INSTANCE_NAME" 10 2>/dev/null; then
  log_error "Cannot reach $INSTANCE_NAME via SSH"
  exit 1
fi

# ── Detect service user ─────────────────────────────────────────────────────
# Checkpoint should run as the user who owns the workspace

SVC_USER=$(ssh_exec "$INSTANCE_NAME" "bash -c '
  USR=\$(systemctl show -p User openclaw-gateway 2>/dev/null | cut -d= -f2)
  [[ -z \"\$USR\" ]] && USR=\$(ps -eo user,comm 2>/dev/null | grep -i openclaw | awk \"{print \\\$1}\" | head -1)
  [[ -z \"\$USR\" ]] && USR=root
  echo \"\$USR\"
'" 2>/dev/null) || true
SVC_USER="${SVC_USER:-root}"
SVC_USER=$(echo "$SVC_USER" | tr -d '[:space:]')

# ── Run checkpoint ──────────────────────────────────────────────────────────

CKPT_CMD="proactive-amcp checkpoint"
[[ "$FULL" == true ]] && CKPT_CMD="proactive-amcp full-checkpoint"

if [[ "$SVC_USER" != "$INSTANCE_SSH_USER" && "$SVC_USER" != "root" ]]; then
  log_info "Running full checkpoint as $SVC_USER..."
  RESULT=$(ssh_exec "$INSTANCE_NAME" "su - $SVC_USER -s /bin/bash -c '$CKPT_CMD' 2>&1" 2>/dev/null) || true
else
  if [[ "$FULL" == true ]]; then
    log_info "Running full checkpoint..."
  else
    log_info "Running checkpoint..."
  fi
  RESULT=$(ssh_exec "$INSTANCE_NAME" "$CKPT_CMD 2>&1" 2>/dev/null) || true
fi

# ── Extract CID from output or last-checkpoint.json ─────────────────────────

CID=$(echo "$RESULT" | grep -oP 'bafkrei[a-z2-7]+' | head -1 || true)

if [[ -z "$CID" ]]; then
  # Fall back to reading last-checkpoint.json
  CID=$(ssh_exec "$INSTANCE_NAME" \
    'python3 -c "import json,os; print(json.load(open(os.path.expanduser(\"~/.amcp/last-checkpoint.json\"))).get(\"cid\",\"\"))" 2>/dev/null' 2>/dev/null) || true
  CID=$(echo "$CID" | tr -d '[:space:]')
fi

# ── Report ──────────────────────────────────────────────────────────────────

if [[ -n "$CID" && "$CID" == bafkrei* ]]; then
  TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log_success "Checkpoint: $CID"
  echo "  Timestamp: $TIMESTAMP"
  if [[ "$FULL" == true ]]; then
    echo "  Type:      full"
  else
    echo "  Type:      quick"
  fi

  # Update metadata
  update_metadata "$INSTANCE_NAME" \
    ".last_checkpoint_cid = \"$CID\" | .last_checkpoint_at = \"$TIMESTAMP\""
else
  log_warn "Checkpoint may have completed but CID not captured"
  echo "$RESULT" | tail -5
fi

echo
