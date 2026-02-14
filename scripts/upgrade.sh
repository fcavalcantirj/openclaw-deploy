#!/usr/bin/env bash
set -euo pipefail

# upgrade.sh - Upgrade tool stack on an OpenClaw instance
# Usage: ./scripts/upgrade.sh <instance-name> [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat << EOF
Usage: $0 <instance-name> [options]

Install or update the tool stack on a deployed OpenClaw instance.

Tools managed:
  - proactive-amcp   Checkpoints, watchdog, self-healing
  - Claude Code CLI  On-VM coding tasks, claude-diagnose
  - Solvr skill      Knowledge search during diagnose

Options:
  --dry-run    Show what would be done without making changes
  -h, --help   Show this help message

Examples:
  $0 jack              # Upgrade all missing/outdated tools
  $0 jack --dry-run    # Preview without changes

EOF
  exit 1
}

# Parse arguments
if [[ $# -lt 1 ]]; then
  usage
fi

INSTANCE_NAME=""
DRY_RUN=false

INSTANCE_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; shift ;;
    -h|--help)  usage ;;
    *)          log_error "Unknown option: $1"; exit 1 ;;
  esac
done

load_instance "$INSTANCE_NAME" || exit 1

if [[ ! -f "$INSTANCE_SSH_KEY" ]]; then
  log_error "SSH key not found: $INSTANCE_SSH_KEY"
  exit 1
fi

echo
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Upgrade Tool Stack: $INSTANCE_NAME${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo

# Verify SSH connectivity
log_info "Connecting to $INSTANCE_IP..."
if ! ssh_check "$INSTANCE_NAME" 10 2>/dev/null; then
  log_error "Cannot reach $INSTANCE_NAME via SSH"
  exit 1
fi
log_success "Connected"
echo

# Probe current state in a single SSH call
log_info "Checking current tool stack..."
PROBE=$(ssh_exec "$INSTANCE_NAME" "bash -c '
  # proactive-amcp
  PAMCP_DIR=\$HOME/.openclaw/skills/proactive-amcp
  if [ -d \"\$PAMCP_DIR/.git\" ]; then
    echo \"pamcp:git:\$(cd \"\$PAMCP_DIR\" && git rev-parse --short HEAD 2>/dev/null || echo unknown)\"
  elif command -v proactive-amcp &>/dev/null; then
    echo \"pamcp:bin:\$(proactive-amcp --version 2>/dev/null || echo installed)\"
  else
    echo \"pamcp:missing\"
  fi
  # Claude Code CLI
  if command -v claude &>/dev/null; then
    echo \"claude:ok:\$(claude --version 2>/dev/null | head -1 || echo installed)\"
  else
    echo \"claude:missing\"
  fi
  # Solvr skill
  if [ -f \"\$HOME/.claude/skills/solvr/scripts/solvr.sh\" ]; then
    echo \"solvr:ok\"
  else
    echo \"solvr:missing\"
  fi
  # npm available?
  command -v npm &>/dev/null && echo \"npm:ok\" || echo \"npm:missing\"
'" 2>/dev/null || echo "probe:failed")

if echo "$PROBE" | grep -q "^probe:failed"; then
  log_error "Failed to probe tool stack"
  exit 1
fi

PAMCP_STATUS=$(echo "$PROBE" | grep '^pamcp:' || echo "pamcp:error")
CLAUDE_STATUS=$(echo "$PROBE" | grep '^claude:' || echo "claude:error")
SOLVR_STATUS=$(echo "$PROBE" | grep '^solvr:' || echo "solvr:error")
NPM_OK=$(echo "$PROBE" | grep -q '^npm:ok' && echo true || echo false)

# Determine what needs upgrading
NEEDS_PAMCP=false
NEEDS_CLAUDE=false
NEEDS_SOLVR=false

case "$PAMCP_STATUS" in
  pamcp:git:*|pamcp:bin:*)
    log_success "proactive-amcp: ${PAMCP_STATUS#pamcp:*:}" ;;
  *)
    log_warn "proactive-amcp: Not installed"
    NEEDS_PAMCP=true ;;
esac

case "$CLAUDE_STATUS" in
  claude:ok:*)
    log_success "Claude Code CLI: ${CLAUDE_STATUS#claude:ok:}" ;;
  *)
    log_warn "Claude Code CLI: Not installed"
    NEEDS_CLAUDE=true ;;
esac

case "$SOLVR_STATUS" in
  solvr:ok)
    log_success "Solvr skill: Installed" ;;
  *)
    log_warn "Solvr skill: Not installed"
    NEEDS_SOLVR=true ;;
esac

echo

# Nothing to do?
if [[ "$NEEDS_PAMCP" = false && "$NEEDS_CLAUDE" = false && "$NEEDS_SOLVR" = false ]]; then
  log_success "All tools already installed. Nothing to upgrade."
  echo
  exit 0
fi

# Dry run: just report
if [[ "$DRY_RUN" = true ]]; then
  echo -e "${YELLOW}Dry run — would install:${NC}"
  [[ "$NEEDS_PAMCP" = true ]] && echo "  - proactive-amcp (via clawhub or npm)"
  [[ "$NEEDS_CLAUDE" = true ]] && echo "  - Claude Code CLI (via npm)"
  [[ "$NEEDS_SOLVR" = true ]] && echo "  - Solvr skill (via solvr.dev/install.sh)"
  echo
  exit 0
fi

# npm required for pamcp and claude installs
if [[ ("$NEEDS_PAMCP" = true || "$NEEDS_CLAUDE" = true) && "$NPM_OK" = false ]]; then
  log_error "npm not available on $INSTANCE_NAME — cannot install Node packages"
  log_error "SSH in and install Node.js first: claw ssh $INSTANCE_NAME"
  exit 1
fi

# ── Install missing tools ────────────────────────────────────────────────────

INSTALLED=0
FAILED=0

if [[ "$NEEDS_CLAUDE" = true ]]; then
  log_info "Installing Claude Code CLI..."
  if ssh_exec "$INSTANCE_NAME" "npm install -g @anthropic-ai/claude-code 2>&1" 2>/dev/null | tail -3; then
    log_success "Claude Code CLI installed"
    INSTALLED=$((INSTALLED + 1))
  else
    log_error "Claude Code CLI install failed"
    FAILED=$((FAILED + 1))
  fi
  echo
fi

if [[ "$NEEDS_PAMCP" = true ]]; then
  log_info "Installing proactive-amcp..."
  # Try clawhub first, fall back to npm
  PAMCP_RESULT=$(ssh_exec "$INSTANCE_NAME" "bash -c '
    if command -v clawhub &>/dev/null && clawhub install proactive-amcp 2>/dev/null; then
      echo \"ok:clawhub\"
    elif npm install -g proactive-amcp 2>&1; then
      echo \"ok:npm\"
    else
      echo \"fail\"
    fi
  '" 2>/dev/null || echo "fail")

  if echo "$PAMCP_RESULT" | grep -q "^ok:"; then
    METHOD="${PAMCP_RESULT#ok:}"
    log_success "proactive-amcp installed via $METHOD"
    INSTALLED=$((INSTALLED + 1))
  else
    log_error "proactive-amcp install failed"
    FAILED=$((FAILED + 1))
  fi
  echo
fi

if [[ "$NEEDS_SOLVR" = true ]]; then
  log_info "Installing Solvr skill..."
  if ssh_exec "$INSTANCE_NAME" "curl -sL --connect-timeout 10 --max-time 30 'https://solvr.dev/install.sh' | bash 2>&1" 2>/dev/null | tail -3; then
    # Verify it landed
    SOLVR_VERIFY=$(ssh_exec "$INSTANCE_NAME" "[ -f \$HOME/.claude/skills/solvr/scripts/solvr.sh ] && echo ok || echo missing" 2>/dev/null)
    if [[ "$SOLVR_VERIFY" = "ok" ]]; then
      log_success "Solvr skill installed"
      INSTALLED=$((INSTALLED + 1))
    else
      log_error "Solvr skill install script ran but files not found"
      FAILED=$((FAILED + 1))
    fi
  else
    log_error "Solvr skill install failed"
    FAILED=$((FAILED + 1))
  fi
  echo
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
if [[ $FAILED -eq 0 ]]; then
  log_success "Upgrade complete: $INSTALLED tool(s) installed"
else
  log_warn "Upgrade finished: $INSTALLED installed, $FAILED failed"
fi
echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
echo
echo "Next steps:"
echo "  Verify status:       claw status $INSTANCE_NAME"
echo "  Test diagnose:       claw diagnose $INSTANCE_NAME"
echo
