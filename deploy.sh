#!/usr/bin/env bash
# ============================================================================
# deploy.sh — Master orchestration script for OpenClaw deployment
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
INSTANCES_DIR="$SCRIPT_DIR/instances"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${CYAN}${BOLD}▶ $*${NC}\n"; }

usage() {
  cat <<EOF
${BOLD}OpenClaw Deploy — Master Deployment Script${NC}

Usage: $0 [OPTIONS]

Options:
  --name NAME              Instance name (default: auto-generated)
  --region REGION          Hetzner region: nbg1, fsn1, hel1, ash (default: nbg1)
  --anthropic-key KEY      Anthropic API key (or use ANTHROPIC_API_KEY env var)
  --openai-key KEY         OpenAI API key (or use OPENAI_API_KEY env var)
  --skip-tailscale         Skip Tailscale setup
  --skip-skills            Skip OpenAI skills setup
  --skip-monitoring        Skip monitoring setup
  --help                   Show this help message

Environment Variables:
  ANTHROPIC_API_KEY        Anthropic API key (required)
  OPENAI_API_KEY           OpenAI API key (optional, required for skills)

Example:
  # Full deployment with all features
  ./deploy.sh --name mybot --anthropic-key sk-ant-... --openai-key sk-...

  # Basic deployment without optional features
  ANTHROPIC_API_KEY=sk-ant-... ./deploy.sh --name mybot --skip-skills

  # Auto-generated name
  ./deploy.sh --anthropic-key sk-ant-... --openai-key sk-...

EOF
  exit 0
}

# ── Parse arguments ─────────────────────────────────────────────────────────
NAME=""
REGION="nbg1"
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_KEY="${OPENAI_API_KEY:-}"
SKIP_TAILSCALE=false
SKIP_SKILLS=false
SKIP_MONITORING=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --anthropic-key)
      ANTHROPIC_KEY="$2"
      shift 2
      ;;
    --openai-key)
      OPENAI_KEY="$2"
      shift 2
      ;;
    --skip-tailscale)
      SKIP_TAILSCALE=true
      shift
      ;;
    --skip-skills)
      SKIP_SKILLS=true
      shift
      ;;
    --skip-monitoring)
      SKIP_MONITORING=true
      shift
      ;;
    --help)
      usage
      ;;
    *)
      log_error "Unknown argument: $1"
      usage
      ;;
  esac
done

# ── Validate inputs ─────────────────────────────────────────────────────────
if [[ -z "$ANTHROPIC_KEY" ]]; then
  log_error "Anthropic API key is required (use --anthropic-key or ANTHROPIC_API_KEY env var)"
  exit 1
fi

if [[ "$SKIP_SKILLS" == false && -z "$OPENAI_KEY" ]]; then
  log_warn "OpenAI API key not provided. Skills setup will be skipped."
  log_warn "To enable skills, provide --openai-key or set OPENAI_API_KEY env var"
  SKIP_SKILLS=true
fi

# Auto-generate name if not provided
if [[ -z "$NAME" ]]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  NAME="openclaw-${TIMESTAMP}"
  log_info "Auto-generated instance name: $NAME"
fi

# ── Display deployment plan ─────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  ${BOLD}OpenClaw Deployment${NC}"
echo "════════════════════════════════════════════════════════════════════"
echo ""
echo "  Instance:    ${BOLD}$NAME${NC}"
echo "  Region:      $REGION"
echo "  Tailscale:   $([ "$SKIP_TAILSCALE" == true ] && echo "Skip" || echo "Install")"
echo "  Skills:      $([ "$SKIP_SKILLS" == true ] && echo "Skip" || echo "Install")"
echo "  Monitoring:  $([ "$SKIP_MONITORING" == true ] && echo "Skip" || echo "Install")"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Provision VM ────────────────────────────────────────────────────
log_section "Step 1/7: Provisioning Hetzner VM"

if ! "$SCRIPTS_DIR/provision.sh" --name "$NAME" --region "$REGION"; then
  log_error "Provisioning failed"
  exit 1
fi

log_success "VM provisioned successfully"

# Load metadata
METADATA_FILE="$INSTANCES_DIR/$NAME/metadata.json"
if [[ ! -f "$METADATA_FILE" ]]; then
  log_error "Metadata file not found: $METADATA_FILE"
  exit 1
fi

SERVER_IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY_PATH=$(jq -r '.ssh_key_path' "$METADATA_FILE")

log_info "Server IP: $SERVER_IP"
log_info "SSH key: $SSH_KEY_PATH"

# ── Step 2: Bootstrap VM ────────────────────────────────────────────────────
log_section "Step 2/7: Bootstrap VM (Node.js + Claude Code)"

log_info "Copying bootstrap script to VM..."
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$SCRIPTS_DIR/bootstrap.sh" root@"$SERVER_IP":/root/bootstrap.sh

log_info "Running bootstrap script on VM..."
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@"$SERVER_IP" "bash /root/bootstrap.sh"; then
  log_error "Bootstrap failed"
  exit 1
fi

log_success "VM bootstrapped successfully"

# Update metadata status
jq '.status = "bootstrapped"' "$METADATA_FILE" > "${METADATA_FILE}.tmp" && mv "${METADATA_FILE}.tmp" "$METADATA_FILE"

# ── Step 3: Install OpenClaw ────────────────────────────────────────────────
log_section "Step 3/7: Installing OpenClaw Gateway"

if ! "$SCRIPTS_DIR/setup-openclaw.sh" "$NAME" --anthropic-key "$ANTHROPIC_KEY"; then
  log_error "OpenClaw installation failed"
  exit 1
fi

log_success "OpenClaw installed and configured"

# ── Step 4: Setup Tailscale ─────────────────────────────────────────────────
if [[ "$SKIP_TAILSCALE" == false ]]; then
  log_section "Step 4/7: Installing Tailscale"

  if ! "$SCRIPTS_DIR/setup-tailscale.sh" "$NAME" --anthropic-key "$ANTHROPIC_KEY"; then
    log_warn "Tailscale installation failed or was skipped by user"
  else
    log_success "Tailscale configured"

    # Reload metadata to get Tailscale IP
    if jq -e '.tailscale_ip' "$METADATA_FILE" >/dev/null 2>&1; then
      TAILSCALE_IP=$(jq -r '.tailscale_ip' "$METADATA_FILE")
      log_info "Tailscale IP: $TAILSCALE_IP"
    fi
  fi
else
  log_info "Skipping Tailscale setup (--skip-tailscale flag)"
fi

# ── Step 5: Setup Skills ────────────────────────────────────────────────────
if [[ "$SKIP_SKILLS" == false ]]; then
  log_section "Step 5/7: Configuring OpenAI Skills"

  if ! "$SCRIPTS_DIR/setup-skills.sh" "$NAME" --openai-key "$OPENAI_KEY"; then
    log_warn "Skills setup failed"
  else
    log_success "Skills configured"
  fi
else
  log_info "Skipping skills setup (--skip-skills flag or no OpenAI key)"
fi

# ── Step 6: Setup Monitoring ────────────────────────────────────────────────
if [[ "$SKIP_MONITORING" == false ]]; then
  log_section "Step 6/7: Setting up Monitoring"

  if ! "$SCRIPTS_DIR/setup-monitoring.sh" "$NAME"; then
    log_warn "Monitoring setup failed"
  else
    log_success "Monitoring configured"
  fi
else
  log_info "Skipping monitoring setup (--skip-monitoring flag)"
fi

# ── Step 7: Verification ────────────────────────────────────────────────────
log_section "Step 7/7: Running Verification Checks"

if ! "$SCRIPTS_DIR/verify.sh" "$NAME"; then
  log_warn "Some verification checks failed"
else
  log_success "All verification checks passed"
fi

# ── Final Summary ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  ${GREEN}${BOLD}✅ Deployment Complete${NC}"
echo "════════════════════════════════════════════════════════════════════"
echo ""

# Reload final metadata
SERVER_IP=$(jq -r '.ip' "$METADATA_FILE")
TAILSCALE_IP=$(jq -r '.tailscale_ip // "N/A"' "$METADATA_FILE")
STATUS=$(jq -r '.status' "$METADATA_FILE")

echo "  ${BOLD}Instance:${NC}        $NAME"
echo "  ${BOLD}Status:${NC}          $STATUS"
echo "  ${BOLD}Region:${NC}          $REGION"
echo ""
echo "  ${BOLD}Access:${NC}"
echo "    SSH:           ssh -i $SSH_KEY_PATH openclaw@$SERVER_IP"
if [[ "$TAILSCALE_IP" != "N/A" ]]; then
echo "    Tailscale:     ssh openclaw@$TAILSCALE_IP"
fi
echo ""
echo "  ${BOLD}OpenClaw Gateway:${NC}"
echo "    Status:        systemctl --user status openclaw-gateway"
echo "    Logs:          journalctl --user -u openclaw-gateway -f"
echo ""
echo "  ${BOLD}Quick Reference:${NC}"
echo "    Location:      ~/QUICKREF.md on the VM"
echo "    View:          ssh -i $SSH_KEY_PATH openclaw@$SERVER_IP cat QUICKREF.md"
echo ""
echo "  ${BOLD}Next Steps:${NC}"
echo "    1. Configure Telegram bot token:"
echo "       ssh -i $SSH_KEY_PATH openclaw@$SERVER_IP"
echo "       openclaw channels telegram setup"
echo ""
echo "    2. View instance status:"
echo "       ./scripts/status.sh $NAME"
echo ""
echo "    3. List all instances:"
echo "       ./scripts/list.sh"
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo ""
