#!/usr/bin/env bash
# =============================================================================
# setup-amcp.sh — One-command AMCP bootstrap on a child instance
# =============================================================================
# Usage: ./scripts/setup-amcp.sh NAME [--force] [--dry-run]
#
# Each step is idempotent (skips if already done).
# Steps:
#   1. SSH check
#   2. Install amcp CLI
#   3. Install proactive-amcp
#   4. Create AMCP identity (real KERI)
#   5. Push config from parent credentials
#   6. Install watchdog
#   7. Run first checkpoint
#   8. Update metadata
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [--force] [--dry-run]

Bootstrap AMCP on a child instance (identity, config, watchdog, first checkpoint).
Each step is idempotent — safe to run multiple times.

Arguments:
  NAME    Instance name

Options:
  --force     Recreate identity even if one exists
  --dry-run   Preview what would be done without making changes

Examples:
  $(basename "$0") jack              # Full bootstrap
  $(basename "$0") jack --dry-run    # Preview
  $(basename "$0") jack --force      # Recreate identity

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
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

echo
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Setup AMCP: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

# ── Step 1: SSH check ───────────────────────────────────────────────────────

log_info "Step 1: Checking SSH connectivity..."
if ! ssh_check "$INSTANCE_NAME" 10 2>/dev/null; then
  log_error "Cannot reach $INSTANCE_NAME via SSH"
  exit 1
fi
log_success "Connected"
echo

# ── Probe current state in a single SSH call ────────────────────────────────

log_info "Probing current state..."
PROBE=$(ssh_exec "$INSTANCE_NAME" "bash -c '
  # npm
  command -v npm &>/dev/null && echo \"npm:ok\" || echo \"npm:missing\"
  # amcp CLI
  command -v amcp &>/dev/null && echo \"amcp:ok:\$(amcp --version 2>/dev/null || echo installed)\" || echo \"amcp:missing\"
  # proactive-amcp
  PAMCP_DIR=\$HOME/.openclaw/skills/proactive-amcp
  if [ -d \"\$PAMCP_DIR/.git\" ]; then
    echo \"pamcp:git:\$(cd \"\$PAMCP_DIR\" && git rev-parse --short HEAD 2>/dev/null || echo unknown)\"
  elif command -v proactive-amcp &>/dev/null; then
    echo \"pamcp:bin:\$(proactive-amcp --version 2>/dev/null || echo installed)\"
  else
    echo \"pamcp:missing\"
  fi
  # Identity
  if [ -f \"\$HOME/.amcp/identity.json\" ]; then
    AID=\$(python3 -c \"import json; print(json.load(open(\\\"\$HOME/.amcp/identity.json\\\")).get(\\\"aid\\\",\\\"\\\"))\" 2>/dev/null || echo \"\")
    echo \"identity:exists:\${AID}\"
  else
    echo \"identity:missing\"
  fi
  # Watchdog
  systemctl is-active amcp-watchdog 2>/dev/null && echo \"watchdog:active\" || echo \"watchdog:inactive\"
'" 2>/dev/null || echo "probe:failed")

if echo "$PROBE" | grep -q "^probe:failed"; then
  log_error "Failed to probe current state"
  exit 1
fi

NPM_OK=$(echo "$PROBE" | grep -q '^npm:ok' && echo true || echo false)
AMCP_CLI_STATUS=$(echo "$PROBE" | grep '^amcp:' || echo "amcp:error")
PAMCP_STATUS=$(echo "$PROBE" | grep '^pamcp:' || echo "pamcp:error")
IDENTITY_STATUS=$(echo "$PROBE" | grep '^identity:' || echo "identity:error")
WATCHDOG_STATUS=$(echo "$PROBE" | grep '^watchdog:' || echo "watchdog:error")

# ── Dry run: report and exit ────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${YELLOW}Dry run — current state:${NC}"
  echo "  npm:             $NPM_OK"
  echo "  amcp CLI:        $AMCP_CLI_STATUS"
  echo "  proactive-amcp:  $PAMCP_STATUS"
  echo "  Identity:        $IDENTITY_STATUS"
  echo "  Watchdog:        $WATCHDOG_STATUS"
  echo
  echo -e "${YELLOW}Would perform:${NC}"

  case "$AMCP_CLI_STATUS" in
    amcp:ok:*) echo "  [skip] amcp CLI already installed" ;;
    *)         echo "  [install] amcp CLI via npm" ;;
  esac
  case "$PAMCP_STATUS" in
    pamcp:git:*|pamcp:bin:*) echo "  [skip] proactive-amcp already installed" ;;
    *)                       echo "  [install] proactive-amcp via clawhub/npm" ;;
  esac
  case "$IDENTITY_STATUS" in
    identity:exists:B*)
      if [[ "$FORCE" == true ]]; then
        echo "  [recreate] AMCP identity (--force)"
      else
        echo "  [skip] AMCP identity exists"
      fi
      ;;
    *) echo "  [create] AMCP identity" ;;
  esac
  echo "  [push] Config from credentials.json"
  case "$WATCHDOG_STATUS" in
    watchdog:active) echo "  [skip] Watchdog already active" ;;
    *)               echo "  [install] Watchdog service" ;;
  esac
  echo "  [run] First checkpoint"
  echo
  exit 0
fi

# ── Step 2: Install amcp CLI ───────────────────────────────────────────────

echo -e "${BLUE}Step 2: amcp CLI${NC}"
case "$AMCP_CLI_STATUS" in
  amcp:ok:*)
    log_success "Already installed (${AMCP_CLI_STATUS#amcp:ok:})"
    ;;
  *)
    if [[ "$NPM_OK" == false ]]; then
      log_error "npm not available — cannot install amcp CLI"
      log_error "SSH in and install Node.js first: claw ssh $INSTANCE_NAME"
      exit 1
    fi
    log_info "Installing amcp-protocol CLI..."
    RESULT=$(ssh_exec "$INSTANCE_NAME" "npm install -g amcp-protocol 2>&1 && echo 'INSTALL_OK' || echo 'INSTALL_FAIL'" 2>/dev/null)
    if echo "$RESULT" | grep -q "INSTALL_OK"; then
      log_success "amcp CLI installed"
    else
      log_error "amcp CLI install failed"
      echo "$RESULT" | tail -5
      exit 1
    fi
    ;;
esac
echo

# ── Step 3: Install proactive-amcp ─────────────────────────────────────────

echo -e "${BLUE}Step 3: proactive-amcp${NC}"
case "$PAMCP_STATUS" in
  pamcp:git:*|pamcp:bin:*)
    log_success "Already installed (${PAMCP_STATUS#pamcp:*:})"
    ;;
  *)
    log_info "Installing proactive-amcp..."
    RESULT=$(ssh_exec "$INSTANCE_NAME" "bash -c '
      if command -v clawhub &>/dev/null && clawhub install proactive-amcp 2>/dev/null; then
        echo \"ok:clawhub\"
      elif npm install -g proactive-amcp 2>&1; then
        echo \"ok:npm\"
      else
        echo \"fail\"
      fi
    '" 2>/dev/null || echo "fail")

    if echo "$RESULT" | grep -q "^ok:"; then
      METHOD="${RESULT#ok:}"
      log_success "Installed via $METHOD"
    else
      log_error "proactive-amcp install failed"
      exit 1
    fi
    ;;
esac
echo

# ── Step 4: Create AMCP identity ───────────────────────────────────────────

echo -e "${BLUE}Step 4: AMCP identity${NC}"
NEED_IDENTITY=false
case "$IDENTITY_STATUS" in
  identity:exists:B*)
    if [[ "$FORCE" == true ]]; then
      log_warn "Recreating identity (--force)"
      NEED_IDENTITY=true
    else
      AID="${IDENTITY_STATUS#identity:exists:}"
      log_success "Identity exists: ${AID:0:12}..."
    fi
    ;;
  *)
    NEED_IDENTITY=true
    ;;
esac

if [[ "$NEED_IDENTITY" == true ]]; then
  log_info "Creating real KERI identity..."
  IDENTITY_RESULT=$(ssh_exec "$INSTANCE_NAME" "bash -c '
    SEED=\$(openssl rand -hex 32)
    echo \"SEED:\${SEED}\"
    mkdir -p \$HOME/.amcp
    amcp identity create --seed \"\$SEED\" --out \$HOME/.amcp/identity.json 2>&1
    echo \"CREATE_DONE\"
    AID=\$(python3 -c \"import json; print(json.load(open(\\\"\$HOME/.amcp/identity.json\\\")).get(\\\"aid\\\",\\\"\\\"))\" 2>/dev/null || echo \"\")
    echo \"AID:\${AID}\"
  '" 2>/dev/null)

  SEED=$(echo "$IDENTITY_RESULT" | grep '^SEED:' | head -1 | cut -d: -f2)
  NEW_AID=$(echo "$IDENTITY_RESULT" | grep '^AID:' | head -1 | cut -d: -f2)

  if [[ -n "$NEW_AID" && "$NEW_AID" == B* ]]; then
    log_success "Identity created: ${NEW_AID:0:12}..."
    # Store seed in metadata for recovery
    update_metadata "$INSTANCE_NAME" \
      ".amcp_aid = \"$NEW_AID\" | .amcp_seed = \"$SEED\" | .amcp_identity_created = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  else
    log_error "Identity creation failed"
    echo "$IDENTITY_RESULT" | tail -5
    exit 1
  fi
fi
echo

# ── Step 5: Push config from credentials ───────────────────────────────────

echo -e "${BLUE}Step 5: Push config${NC}"
"$SCRIPT_DIR/remote-config.sh" "$INSTANCE_NAME" --push
echo

# ── Step 6: Install watchdog ───────────────────────────────────────────────

echo -e "${BLUE}Step 6: Watchdog service${NC}"
case "$WATCHDOG_STATUS" in
  watchdog:active)
    log_success "Already active"
    ;;
  *)
    log_info "Installing watchdog..."
    RESULT=$(ssh_exec "$INSTANCE_NAME" \
      "proactive-amcp install --watchdog-interval 120 --service openclaw-gateway --port 18789 2>&1 && echo 'INSTALL_OK' || echo 'INSTALL_FAIL'" 2>/dev/null)
    if echo "$RESULT" | grep -q "INSTALL_OK"; then
      log_success "Watchdog installed"
    else
      log_warn "Watchdog install may have issues"
      echo "$RESULT" | tail -3
    fi
    ;;
esac
echo

# ── Step 7: First checkpoint ──────────────────────────────────────────────

echo -e "${BLUE}Step 7: First checkpoint${NC}"
log_info "Running checkpoint..."
CKPT_RESULT=$(ssh_exec "$INSTANCE_NAME" \
  "proactive-amcp checkpoint 2>&1 || echo 'CHECKPOINT_FAIL'" 2>/dev/null)

if echo "$CKPT_RESULT" | grep -q "CHECKPOINT_FAIL"; then
  log_warn "Checkpoint had issues (identity/config may need settling)"
else
  # Try to extract CID
  CID=$(echo "$CKPT_RESULT" | grep -oP 'bafkrei[a-z2-7]+' | head -1)
  if [[ -n "$CID" ]]; then
    log_success "Checkpoint created: ${CID:0:16}..."
    update_metadata "$INSTANCE_NAME" \
      ".last_checkpoint_cid = \"$CID\" | .last_checkpoint_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  else
    log_success "Checkpoint completed"
  fi
fi
echo

# ── Step 8: Update metadata ─────────────────────────────────────────────────

update_metadata "$INSTANCE_NAME" ".amcp_status = \"bootstrapped\" | .amcp_setup_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
log_success "AMCP setup complete for $INSTANCE_NAME"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo
echo "Next steps:"
echo "  Verify:    claw diagnose $INSTANCE_NAME"
echo "  Config:    claw config $INSTANCE_NAME --show"
echo
