#!/usr/bin/env bash
set -euo pipefail

# config-view.sh - View and update OpenClaw configuration on an instance
# Usage: ./scripts/config-view.sh <instance-name> [options]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$PROJECT_ROOT/instances"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Functions
error() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  exit 1
}

info() {
  echo -e "${BLUE}INFO: $1${NC}"
}

success() {
  echo -e "${GREEN}✓ $1${NC}"
}

warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

usage() {
  cat << EOF
Usage: $0 <instance-name> [options]

View or update OpenClaw configuration on a deployed instance.

Arguments:
  instance-name    Name of the deployed instance

Options:
  -v, --view       View current configuration (default)
  -e, --edit       Edit configuration interactively
  -d, --download   Download config to local file
  -u, --upload F   Upload config from local file
  -b, --backup     Create backup before any changes
  -h, --help       Show this help message

Examples:
  $0 mybot                           # View current config
  $0 mybot --view                    # View current config
  $0 mybot --download                # Download to instances/mybot/config.json
  $0 mybot --upload config.json      # Upload from local file
  $0 mybot --edit                    # Edit via SSH (requires editor on VM)

Configuration location on VM:
  ~/.openclaw/openclaw.json

Important notes:
  • Gateway must be restarted after config changes
  • Always backup before major changes
  • Invalid config may prevent gateway from starting

EOF
  exit 1
}

# Parse arguments
INSTANCE_NAME=""
ACTION="view"
LOCAL_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--view)
      ACTION="view"
      shift
      ;;
    -e|--edit)
      ACTION="edit"
      shift
      ;;
    -d|--download)
      ACTION="download"
      shift
      ;;
    -u|--upload)
      ACTION="upload"
      LOCAL_FILE="$2"
      shift 2
      ;;
    -b|--backup)
      ACTION="backup"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ -z "$INSTANCE_NAME" ]; then
        INSTANCE_NAME="$1"
        shift
      else
        error "Unknown option: $1"
      fi
      ;;
  esac
done

# Validate instance name
if [ -z "$INSTANCE_NAME" ]; then
  usage
fi

# Check if instance exists
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_NAME"
METADATA_FILE="$INSTANCE_DIR/metadata.json"

if [ ! -f "$METADATA_FILE" ]; then
  error "Instance '$INSTANCE_NAME' not found. Run ./scripts/list.sh to see available instances."
fi

# Load instance metadata
IP=$(jq -r '.ip' "$METADATA_FILE")
SSH_KEY=$(jq -r '.ssh_key' "$METADATA_FILE")

if [ -z "$IP" ] || [ "$IP" = "null" ]; then
  error "Instance IP not found in metadata"
fi

if [ ! -f "$SSH_KEY" ]; then
  error "SSH key not found at $SSH_KEY"
fi

CONFIG_PATH="~/.openclaw/openclaw.json"

echo
info "Managing configuration for: $INSTANCE_NAME"
info "Instance IP: $IP"
info "Action: $ACTION"
echo

# Execute action
case $ACTION in
  view)
    info "Fetching configuration..."
    echo

    CONFIG_CONTENT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "cat $CONFIG_PATH 2>&1" || echo "FETCH_FAILED")

    if [ "$CONFIG_CONTENT" = "FETCH_FAILED" ] || echo "$CONFIG_CONTENT" | grep -qi "no such file"; then
      error "Failed to fetch configuration. Config file may not exist."
    fi

    # Pretty print JSON with color
    echo "$CONFIG_CONTENT" | jq . 2>/dev/null || echo "$CONFIG_CONTENT"

    echo
    success "Configuration displayed"
    echo

    echo -e "${BLUE}Next steps:${NC}"
    echo -e "  • Download config: ${YELLOW}$0 $INSTANCE_NAME --download${NC}"
    echo -e "  • Edit on VM: ${YELLOW}$0 $INSTANCE_NAME --edit${NC}"
    echo -e "  • Upload new config: ${YELLOW}$0 $INSTANCE_NAME --upload config.json${NC}"
    echo
    ;;

  download)
    info "Downloading configuration..."

    # Ensure instance directory exists
    mkdir -p "$INSTANCE_DIR"

    DOWNLOAD_FILE="$INSTANCE_DIR/config.json"

    CONFIG_CONTENT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "cat $CONFIG_PATH 2>&1" || echo "FETCH_FAILED")

    if [ "$CONFIG_CONTENT" = "FETCH_FAILED" ]; then
      error "Failed to download configuration"
    fi

    echo "$CONFIG_CONTENT" > "$DOWNLOAD_FILE"

    success "Configuration downloaded to: $DOWNLOAD_FILE"
    echo

    # Validate JSON
    if jq . "$DOWNLOAD_FILE" > /dev/null 2>&1; then
      success "Configuration is valid JSON"
    else
      warning "Downloaded file may not be valid JSON"
    fi

    echo
    echo -e "${BLUE}File saved at:${NC} ${CYAN}$DOWNLOAD_FILE${NC}"
    echo
    ;;

  upload)
    if [ -z "$LOCAL_FILE" ]; then
      error "Upload requires a file path. Usage: $0 $INSTANCE_NAME --upload <file>"
    fi

    if [ ! -f "$LOCAL_FILE" ]; then
      error "File not found: $LOCAL_FILE"
    fi

    info "Validating local config file..."

    if ! jq . "$LOCAL_FILE" > /dev/null 2>&1; then
      error "Invalid JSON in file: $LOCAL_FILE"
    fi

    success "Local config is valid JSON"
    echo

    # Create backup first
    info "Creating backup on VM..."
    BACKUP_NAME="openclaw.json.backup.$(date +%Y%m%d_%H%M%S)"

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "cp $CONFIG_PATH ~/.openclaw/$BACKUP_NAME 2>&1 || echo 'BACKUP_FAILED'" > /dev/null

    success "Backup created: ~/.openclaw/$BACKUP_NAME"
    echo

    # Upload new config
    info "Uploading new configuration..."

    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$LOCAL_FILE" "openclaw@$IP:$CONFIG_PATH" || \
      error "Failed to upload configuration"

    success "Configuration uploaded"
    echo

    # Validate on remote
    info "Validating uploaded config..."

    VALIDATE_OUTPUT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "jq . $CONFIG_PATH > /dev/null 2>&1 && echo 'VALID' || echo 'INVALID'")

    if [ "$VALIDATE_OUTPUT" = "INVALID" ]; then
      warning "Uploaded config may be invalid. Restoring backup..."
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "openclaw@$IP" "cp ~/.openclaw/$BACKUP_NAME $CONFIG_PATH"
      error "Upload failed validation. Backup restored."
    fi

    success "Configuration validated successfully"
    echo

    warning "Gateway must be restarted for changes to take effect"
    echo -e "${YELLOW}Restart now? (y/N)${NC} "
    read -r RESTART_CONFIRM

    if [[ "$RESTART_CONFIRM" =~ ^[Yy]$ ]]; then
      echo
      info "Restarting gateway..."
      "$SCRIPT_DIR/restart.sh" "$INSTANCE_NAME"
    else
      echo
      info "Skipping restart. Remember to restart manually:"
      echo -e "  ${YELLOW}./scripts/restart.sh $INSTANCE_NAME${NC}"
      echo
    fi
    ;;

  edit)
    info "Opening SSH session for config editing..."
    echo

    warning "This will open an SSH session with editor"
    warning "You must have an editor (nano, vim, etc.) configured on the VM"
    echo

    # Check if editor is available
    EDITOR_CHECK=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "command -v nano || command -v vim || command -v vi || echo 'NO_EDITOR'")

    if [ "$EDITOR_CHECK" = "NO_EDITOR" ]; then
      error "No editor found on VM. Install nano or vim first."
    fi

    info "Editor found: $EDITOR_CHECK"
    info "Opening config in editor..."
    echo

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      -t "openclaw@$IP" "$EDITOR_CHECK $CONFIG_PATH"

    echo
    success "Edit session complete"
    echo

    warning "Remember to restart the gateway for changes to take effect:"
    echo -e "  ${YELLOW}./scripts/restart.sh $INSTANCE_NAME${NC}"
    echo
    ;;

  backup)
    info "Creating configuration backup..."

    BACKUP_NAME="openclaw.json.backup.$(date +%Y%m%d_%H%M%S)"

    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "cp $CONFIG_PATH ~/.openclaw/$BACKUP_NAME 2>&1" || \
      error "Failed to create backup"

    success "Backup created: ~/.openclaw/$BACKUP_NAME"
    echo

    # List all backups
    info "Available backups:"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "openclaw@$IP" "ls -lh ~/.openclaw/openclaw.json.backup.* 2>&1 || echo 'No backups found'"
    echo
    ;;

  *)
    error "Unknown action: $ACTION"
    ;;
esac
