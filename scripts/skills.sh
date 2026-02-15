#!/usr/bin/env bash
# =============================================================================
# skills.sh — List/install/update skills on a child instance via ClawdHub
# =============================================================================
# Usage:
#   ./scripts/skills.sh NAME                      # list skills
#   ./scripts/skills.sh NAME --install SKILL      # install a skill
#   ./scripts/skills.sh NAME --update             # update all skills
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME [options]

List, install, or update skills on a child instance via ClawdHub.

Arguments:
  NAME               Instance name

Options:
  --install SKILL    Install a skill (e.g. openai-whisper)
  --update           Update all installed skills
  --list             Show all skills (default)

Examples:
  $(basename "$0") jack                          # list skills
  $(basename "$0") jack --install openai-whisper # install a skill
  $(basename "$0") jack --update                 # update all skills

EOF
  exit 1
}

# ── Argument parsing ─────────────────────────────────────────────────────────

INSTANCE_NAME=""
INSTALL_SKILL=""
DO_UPDATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      shift
      [[ $# -lt 1 ]] && { log_error "--install requires a skill name"; usage; }
      INSTALL_SKILL="$1"; shift
      ;;
    --update) DO_UPDATE=true; shift ;;
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

# ── Show skills ──────────────────────────────────────────────────────────────

do_show() {
  echo
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Skills: $INSTANCE_NAME ($INSTANCE_IP)${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo

  local raw
  raw=$(ssh_exec "$INSTANCE_NAME" "openclaw skills list 2>&1" 2>/dev/null) || raw="(failed to list skills)"

  echo "$raw" | sed 's/^/  /'
  echo
}

# ── Install skill ────────────────────────────────────────────────────────────

do_install() {
  log_info "Installing skill on $INSTANCE_NAME: $INSTALL_SKILL"

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "clawhub install '$INSTALL_SKILL' 2>&1" 2>/dev/null)
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    log_success "Skill installed: $INSTALL_SKILL"
  else
    log_error "Failed to install skill: $INSTALL_SKILL"
    echo "$result" | sed 's/^/  /'
    exit 1
  fi

  echo "$result" | sed 's/^/  /'
  echo
}

# ── Update skills ────────────────────────────────────────────────────────────

do_update() {
  log_info "Updating skills on $INSTANCE_NAME..."

  local result
  result=$(ssh_exec "$INSTANCE_NAME" "clawhub update 2>&1" 2>/dev/null)
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    log_success "Skills updated"
  else
    log_warn "Some skills may have failed to update"
  fi

  echo "$result" | sed 's/^/  /'
  echo
}

# ── Main dispatch ────────────────────────────────────────────────────────────

if [[ -n "$INSTALL_SKILL" ]]; then
  do_install
elif [[ "$DO_UPDATE" == "true" ]]; then
  do_update
else
  do_show
fi
