#!/usr/bin/env bash
# setup-tailscale.sh
# Runs Claude Code on the VM to install and configure Tailscale
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"
PROMPTS_DIR="$PROJECT_ROOT/prompts"

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

Run Claude Code on VM to install and configure Tailscale.

Arguments:
  instance-name          Name of the instance (required)

Options:
  --anthropic-key KEY    Anthropic API key (can also use ANTHROPIC_API_KEY env var)
  --help                 Show this help message

Example:
  $0 mybot --anthropic-key sk-ant-...
  ANTHROPIC_API_KEY=sk-ant-... $0 mybot

Note: Tailscale requires user authentication. The script will output an auth URL
      that you need to visit to complete the setup.

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --anthropic-key)
      ANTHROPIC_KEY="$2"
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

if [[ -z "$ANTHROPIC_KEY" ]]; then
  log_error "Anthropic API key is required (use --anthropic-key or ANTHROPIC_API_KEY env var)"
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

# Check if prompt file exists
SETUP_PROMPT="$PROMPTS_DIR/setup-tailscale.md"
if [[ ! -f "$SETUP_PROMPT" ]]; then
  log_error "Setup prompt not found: $SETUP_PROMPT"
  exit 1
fi

log_info "Setting up Tailscale on instance '$INSTANCE_NAME' (IP: $IP)"

# Test SSH connectivity first
log_info "Testing SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$IP" "echo 'SSH OK'" >/dev/null 2>&1; then
  log_error "Cannot connect via SSH to openclaw@$IP"
  log_info "Make sure bootstrap.sh has completed successfully"
  exit 1
fi

# Check if Tailscale might already be installed
log_info "Checking current Tailscale status..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "command -v tailscale >/dev/null 2>&1 && tailscale status 2>/dev/null | grep -q '100\.' && echo 'ALREADY_CONNECTED'" | grep -q "ALREADY_CONNECTED"; then
  log_warn "Tailscale appears to already be installed and connected on this VM"

  # Get the current Tailscale IP
  TAILSCALE_IP=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "tailscale ip -4 2>/dev/null" || echo "")

  if [[ -n "$TAILSCALE_IP" ]]; then
    log_info "Current Tailscale IP: $TAILSCALE_IP"

    # Update metadata with Tailscale IP
    jq --arg ts_ip "$TAILSCALE_IP" '.tailscale_ip = $ts_ip | .updated_at = now | .updated_at |= todate' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"

    log_info ""
    log_info "✓ Tailscale is already configured!"
    log_info ""
    log_info "Access this VM via Tailscale:"
    log_info "  ssh openclaw@$TAILSCALE_IP"
    log_info ""
    log_info "To reconfigure Tailscale, run: ssh -i $SSH_KEY openclaw@$IP 'sudo tailscale down && sudo tailscale up'"
    exit 0
  fi
fi

# Copy the setup prompt to the VM
log_info "Copying Tailscale setup prompt to VM..."
if ! scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SETUP_PROMPT" "openclaw@$IP:/home/openclaw/setup-tailscale.md"; then
  log_error "Failed to copy setup prompt to VM"
  exit 1
fi

# Run Claude Code on the VM
log_info ""
log_notice "═══════════════════════════════════════════════════════════"
log_notice "  Running Claude Code on VM to configure Tailscale"
log_notice "═══════════════════════════════════════════════════════════"
log_info ""
log_info "Claude Code will:"
log_info "  1. Install Tailscale from official script"
log_info "  2. Start Tailscale and output an authentication URL"
log_info "  3. Wait for you to authenticate via the URL"
log_info "  4. Verify the connection and output the Tailscale IP"
log_info ""
log_warn "⚠️  IMPORTANT: Watch for the authentication URL and click it!"
log_info ""

# Create a script on the VM that will run Claude Code
REMOTE_SCRIPT="/tmp/run-claude-tailscale.sh"
cat > /tmp/local-claude-runner-tailscale.sh <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Set the API key
export ANTHROPIC_API_KEY="$1"

# Read the prompt
PROMPT_FILE="$HOME/setup-tailscale.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Setup prompt not found at $PROMPT_FILE"
  exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

# Run Claude Code with the prompt
echo "Starting Tailscale setup with Claude Code..."
echo "════════════════════════════════════════════"
echo ""

# Use the --print flag to run in non-interactive mode
claude --print "$PROMPT"

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "════════════════════════════════════════════"
  echo "✓ Tailscale setup completed successfully!"
  exit 0
else
  echo ""
  echo "════════════════════════════════════════════"
  echo "✗ ERROR: Tailscale setup failed with exit code $EXIT_CODE"
  exit $EXIT_CODE
fi
EOFSCRIPT

# Copy the runner script to the VM
if ! scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/local-claude-runner-tailscale.sh "openclaw@$IP:$REMOTE_SCRIPT"; then
  log_error "Failed to copy runner script to VM"
  rm -f /tmp/local-claude-runner-tailscale.sh
  exit 1
fi
rm -f /tmp/local-claude-runner-tailscale.sh

# Make it executable and run it
# We don't capture output because we want the user to see the auth URL in real-time
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "chmod +x $REMOTE_SCRIPT && $REMOTE_SCRIPT '$ANTHROPIC_KEY'"; then
  log_error ""
  log_error "Tailscale setup failed on VM"
  log_info ""
  log_info "Troubleshooting steps:"
  log_info "  1. SSH to the VM: ssh -i $SSH_KEY openclaw@$IP"
  log_info "  2. Check Tailscale status: tailscale status"
  log_info "  3. Try manual setup: sudo tailscale up"
  log_info "  4. Check Claude Code logs: ls -lh ~/.claude/"
  exit 1
fi

# Get the Tailscale IP from the VM
log_info ""
log_info "Retrieving Tailscale IP address..."
TAILSCALE_IP=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "tailscale ip -4 2>/dev/null" || echo "")

if [[ -z "$TAILSCALE_IP" ]]; then
  log_warn "Could not retrieve Tailscale IP address"
  log_info "You can get it later by running: ssh -i $SSH_KEY openclaw@$IP 'tailscale ip -4'"
else
  log_info "Tailscale IP: $TAILSCALE_IP"

  # Update metadata with Tailscale IP
  jq --arg ts_ip "$TAILSCALE_IP" '.tailscale_ip = $ts_ip | .status = "tailscale-configured" | .updated_at = now | .updated_at |= todate' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
fi

log_info ""
log_info "═══════════════════════════════════════════════════════════"
log_info "  ✓ Tailscale setup completed successfully!"
log_info "═══════════════════════════════════════════════════════════"
log_info ""

if [[ -n "$TAILSCALE_IP" ]]; then
  log_info "Access your VM securely from anywhere on your Tailnet:"
  log_info ""
  log_info "  Direct SSH:"
  log_info "    ssh openclaw@$TAILSCALE_IP"
  log_info ""
  log_info "  Access OpenClaw Gateway (via SSH tunnel):"
  log_info "    ssh -N -L 18789:127.0.0.1:18789 openclaw@$TAILSCALE_IP"
  log_info "    Then open: http://localhost:18789/openclaw"
  log_info ""
  log_info "  Or continue using the direct IP:"
  log_info "    ssh -i $SSH_KEY openclaw@$IP"
  log_info ""
fi

exit 0
