#!/usr/bin/env bash
# setup-openclaw.sh
# Runs Claude Code on the VM to install and configure OpenClaw Gateway
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTANCES_DIR="$PROJECT_ROOT/instances"
PROMPTS_DIR="$PROJECT_ROOT/prompts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
  cat <<EOF
Usage: $0 <instance-name> [OPTIONS]

Run Claude Code on VM to install and configure OpenClaw Gateway.

Arguments:
  instance-name          Name of the instance (required)

Options:
  --anthropic-key KEY    Anthropic API key (can also use ANTHROPIC_API_KEY env var)
  --help                 Show this help message

Example:
  $0 mybot --anthropic-key sk-ant-...
  ANTHROPIC_API_KEY=sk-ant-... $0 mybot

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
SETUP_PROMPT="$PROMPTS_DIR/setup-openclaw.md"
if [[ ! -f "$SETUP_PROMPT" ]]; then
  log_error "Setup prompt not found: $SETUP_PROMPT"
  exit 1
fi

log_info "Setting up OpenClaw on instance '$INSTANCE_NAME' (IP: $IP)"

# Test SSH connectivity first
log_info "Testing SSH connectivity..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o StrictHostKeyChecking=no "openclaw@$IP" "echo 'SSH OK'" >/dev/null 2>&1; then
  log_error "Cannot connect via SSH to openclaw@$IP"
  log_info "Make sure bootstrap.sh has completed successfully"
  exit 1
fi

# Copy the setup prompt to the VM
log_info "Copying setup prompt to VM..."
if ! scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$SETUP_PROMPT" "openclaw@$IP:/home/openclaw/setup-openclaw.md"; then
  log_error "Failed to copy setup prompt to VM"
  exit 1
fi

# Run Claude Code on the VM
log_info "Running Claude Code on VM to configure OpenClaw..."
log_info "This may take several minutes. Claude Code will:"
log_info "  - Install OpenClaw globally via npm"
log_info "  - Configure the gateway (loopback bind, token auth)"
log_info "  - Set up Telegram channel (you'll add bot token later)"
log_info "  - Install and configure Tailscale"
log_info "  - Set up health monitoring"
log_info "  - Create QUICKREF.md with usage instructions"
echo ""

# Create a script on the VM that will run Claude Code
REMOTE_SCRIPT="/tmp/run-claude-setup.sh"
cat > /tmp/local-claude-runner.sh <<'EOFSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Set the API key
export ANTHROPIC_API_KEY="$1"

# Read the prompt
PROMPT_FILE="$HOME/setup-openclaw.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Setup prompt not found at $PROMPT_FILE"
  exit 1
fi

PROMPT=$(cat "$PROMPT_FILE")

# Run Claude Code with the prompt
echo "Starting Claude Code setup..."
echo "================================"

# Use the --print flag to run in non-interactive mode
claude --print "$PROMPT"

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "================================"
  echo "Claude Code setup completed successfully!"
  exit 0
else
  echo ""
  echo "================================"
  echo "ERROR: Claude Code setup failed with exit code $EXIT_CODE"
  exit $EXIT_CODE
fi
EOFSCRIPT

# Copy the runner script to the VM
if ! scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/local-claude-runner.sh "openclaw@$IP:$REMOTE_SCRIPT"; then
  log_error "Failed to copy runner script to VM"
  rm -f /tmp/local-claude-runner.sh
  exit 1
fi
rm -f /tmp/local-claude-runner.sh

# Make it executable and run it
if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "openclaw@$IP" "chmod +x $REMOTE_SCRIPT && $REMOTE_SCRIPT '$ANTHROPIC_KEY'"; then
  log_error "Claude Code setup failed on VM"
  log_info "You can SSH to the VM and check logs:"
  log_info "  ssh -i $SSH_KEY openclaw@$IP"
  exit 1
fi

log_info ""
log_info "✓ OpenClaw setup completed successfully!"
log_info ""
log_info "Next steps:"
log_info "  1. Get a Telegram bot token from @BotFather"
log_info "  2. SSH to the VM: ssh -i $SSH_KEY openclaw@$IP"
log_info "  3. Set the bot token: openclaw config set channels.telegram.botToken 'YOUR_TOKEN'"
log_info "  4. Restart gateway: openclaw gateway restart"
log_info "  5. Check the QUICKREF: cat ~/QUICKREF.md"
log_info ""
log_info "Tailscale auth URL (if printed above) - click it to authenticate your tailnet"

# Update metadata status
jq '.status = "openclaw-installed" | .updated_at = now | .updated_at |= todate' "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"

exit 0
