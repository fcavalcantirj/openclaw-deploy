#!/usr/bin/env bash
# setup-skills.sh
# Configures OpenAI Whisper skill and ClawdHub CLI on the VM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_notice() { echo -e "${BLUE}[NOTICE]${NC} $*"; }

usage() {
  cat <<EOF
Usage: $0 <instance-name> [OPTIONS]

Configure OpenAI Whisper skill and ClawdHub CLI on the VM.

Arguments:
  instance-name          Name of the instance (required)

Options:
  --openai-key KEY       OpenAI API key (can also use OPENAI_API_KEY env var)
  --help                 Show this help message

Example:
  $0 mybot --openai-key sk-...
  OPENAI_API_KEY=sk-... $0 mybot

Note: This script configures the openai-whisper-api skill and installs clawhub CLI.

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
OPENAI_KEY="${OPENAI_API_KEY:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --openai-key)
      OPENAI_KEY="$2"
      shift 2
      ;;
    --help)
      usage
      ;;
    -*)
      log_error "Unknown option: $1"
      usage
      ;;
    *)
      if [[ -z "$INSTANCE_NAME" ]]; then
        INSTANCE_NAME="$1"
      else
        log_error "Multiple instance names provided"
        usage
      fi
      shift
      ;;
  esac
done

# Validate inputs
if [[ -z "$INSTANCE_NAME" ]]; then
  log_error "Instance name is required"
  usage
fi

if [[ -z "$OPENAI_KEY" ]]; then
  log_error "OpenAI API key is required (use --openai-key or OPENAI_API_KEY env var)"
  exit 1
fi

# Check instance exists
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [[ ! -f "$METADATA_FILE" ]]; then
  log_error "Instance '$INSTANCE_NAME' not found at $METADATA_FILE"
  log_info "Run provision.sh first to create the instance"
  exit 1
fi

# Read metadata
IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key' "$METADATA_FILE")

if [[ -z "$IP" ]] || [[ "$IP" == "null" ]]; then
  log_error "No IP address found in metadata"
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  log_error "SSH key not found: $SSH_KEY"
  exit 1
fi

log_info "Setting up skills on instance '$INSTANCE_NAME' (IP: $IP)"

# Test SSH connectivity first
log_info "Testing SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$IP" "echo 'SSH OK'" >/dev/null 2>&1; then
  log_error "Cannot connect via SSH to openclaw@$IP"
  log_info "Make sure bootstrap.sh has completed successfully"
  exit 1
fi

# Check if OpenClaw is installed
log_info "Verifying OpenClaw installation..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "command -v openclaw >/dev/null 2>&1"; then
  log_error "OpenClaw is not installed on the VM"
  log_info "Run setup-openclaw.sh first"
  exit 1
fi

log_info ""
log_notice "═══════════════════════════════════════════════════════════"
log_notice "  Configuring OpenAI Whisper and ClawdHub"
log_notice "═══════════════════════════════════════════════════════════"
log_info ""

# Create configuration script to run on the VM
REMOTE_SCRIPT="/tmp/setup-skills-remote.sh"
cat > /tmp/local-setup-skills.sh <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

OPENAI_KEY="$1"

echo "[1/5] Configuring openai-whisper-api skill..."

# Get the OpenClaw config directory
CONFIG_DIR="$HOME/.openclaw"
OPENCLAW_CONFIG="$CONFIG_DIR/openclaw.json"

if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
  echo "ERROR: OpenClaw config not found at $OPENCLAW_CONFIG"
  exit 1
fi

# Check if openai-whisper-api skill section exists, if not add it
if ! jq -e '.skills."openai-whisper-api"' "$OPENCLAW_CONFIG" >/dev/null 2>&1; then
  echo "Adding openai-whisper-api skill configuration..."

  # Add the skill configuration
  jq --arg api_key "$OPENAI_KEY" \
    '.skills."openai-whisper-api" = {
      "enabled": true,
      "config": {
        "apiKey": $api_key,
        "model": "whisper-1"
      }
    }' "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"

  echo "✓ Added openai-whisper-api skill configuration"
else
  echo "openai-whisper-api skill already configured, updating API key..."

  # Update the API key
  jq --arg api_key "$OPENAI_KEY" \
    '.skills."openai-whisper-api".config.apiKey = $api_key |
     .skills."openai-whisper-api".enabled = true' \
    "$OPENCLAW_CONFIG" > "$OPENCLAW_CONFIG.tmp" && mv "$OPENCLAW_CONFIG.tmp" "$OPENCLAW_CONFIG"

  echo "✓ Updated openai-whisper-api API key"
fi

echo ""
echo "[2/5] Installing ClawdHub CLI..."

# Install clawhub CLI globally
if command -v clawhub >/dev/null 2>&1; then
  echo "ClawdHub CLI already installed, checking version..."
  clawhub --version || true
else
  echo "Installing clawhub from npm..."
  if npm install -g clawhub; then
    echo "✓ ClawdHub CLI installed successfully"
  else
    echo "ERROR: Failed to install clawhub CLI"
    exit 1
  fi
fi

echo ""
echo "[3/5] Verifying ClawdHub installation..."
if command -v clawhub >/dev/null 2>&1; then
  CLAWHUB_VERSION=$(clawhub --version 2>&1 || echo "unknown")
  echo "✓ ClawdHub CLI is available: $CLAWHUB_VERSION"
else
  echo "ERROR: clawhub command not found after installation"
  exit 1
fi

echo ""
echo "[4/5] Verifying Whisper skill configuration..."

# Check if the transcribe.sh script exists (part of openai-whisper-api skill)
SKILL_DIR="$HOME/.openclaw/skills/openai-whisper-api"
if [[ -d "$SKILL_DIR" ]]; then
  echo "✓ openai-whisper-api skill directory exists"

  # List skill files
  if [[ -f "$SKILL_DIR/transcribe.sh" ]]; then
    echo "✓ transcribe.sh script found"
  else
    echo "Note: transcribe.sh not found yet (will be installed when skill is first used)"
  fi
else
  echo "Note: Skill directory not created yet (will be initialized when gateway starts)"
fi

# Verify the configuration is valid JSON
if jq empty "$OPENCLAW_CONFIG" 2>/dev/null; then
  echo "✓ OpenClaw configuration is valid JSON"
else
  echo "ERROR: OpenClaw configuration is invalid JSON"
  exit 1
fi

echo ""
echo "[5/5] Restarting OpenClaw gateway to apply changes..."

# Restart the gateway service to pick up new configuration
if sudo systemctl is-active openclaw-gateway >/dev/null 2>&1; then
  sudo systemctl restart openclaw-gateway

  # Wait a moment for the service to start
  sleep 3

  # Check if it's running
  if sudo systemctl is-active openclaw-gateway >/dev/null 2>&1; then
    echo "✓ OpenClaw gateway restarted successfully"
  else
    echo "ERROR: Gateway failed to restart"
    sudo systemctl status openclaw-gateway --no-pager || true
    exit 1
  fi
else
  echo "Gateway was not running, starting it..."
  sudo systemctl start openclaw-gateway
  sleep 3

  if sudo systemctl is-active openclaw-gateway >/dev/null 2>&1; then
    echo "✓ OpenClaw gateway started successfully"
  else
    echo "ERROR: Gateway failed to start"
    sudo systemctl status openclaw-gateway --no-pager || true
    exit 1
  fi
fi

echo ""
echo "════════════════════════════════════════════"
echo "✓ Skills configuration completed successfully!"
echo "════════════════════════════════════════════"
echo ""
echo "Configured:"
echo "  • openai-whisper-api skill with API key"
echo "  • ClawdHub CLI: $(clawhub --version 2>&1 || echo 'installed')"
echo ""
echo "To test Whisper transcription:"
echo "  openclaw skill run openai-whisper-api transcribe <audio-file>"
echo ""

exit 0
EOFSCRIPT

# Copy the setup script to the VM
log_info "Copying setup script to VM..."
if ! scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/local-setup-skills.sh "openclaw@$IP:$REMOTE_SCRIPT"; then
  log_error "Failed to copy setup script to VM"
  rm -f /tmp/local-setup-skills.sh
  exit 1
fi
rm -f /tmp/local-setup-skills.sh

# Make it executable and run it
log_info "Running skills configuration on VM..."
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "chmod +x $REMOTE_SCRIPT && $REMOTE_SCRIPT '$OPENAI_KEY'"; then
  log_error ""
  log_error "Skills configuration failed on VM"
  log_info ""
  log_info "Troubleshooting steps:"
  log_info "  1. SSH to the VM: ssh -i $SSH_KEY openclaw@$IP"
  log_info "  2. Check OpenClaw config: cat ~/.openclaw/openclaw.json"
  log_info "  3. Check gateway status: sudo systemctl status openclaw-gateway"
  log_info "  4. Check gateway logs: sudo journalctl -u openclaw-gateway -n 50"
  exit 1
fi

# Update metadata status
log_info "Updating instance metadata..."
jq '.status = "skills-configured" | .updated_at = now | .updated_at |= todate' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"

log_info ""
log_info "═══════════════════════════════════════════════════════════"
log_info "  ✓ Skills setup completed successfully!"
log_info "═══════════════════════════════════════════════════════════"
log_info ""
log_info "Next steps:"
log_info "  • Run setup-monitoring.sh to install healthcheck timer"
log_info "  • Run verify.sh to check all components"
log_info ""
log_info "To test the Whisper skill, SSH to the VM and run:"
log_info "  ssh -i $SSH_KEY openclaw@$IP"
log_info "  openclaw skill run openai-whisper-api transcribe <audio-file>"
log_info ""

exit 0
