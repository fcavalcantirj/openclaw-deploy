#!/bin/bash
# Remote management CLI for child instances
# Usage: ./scripts/remote.sh <instance> <command> [args...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$ROOT_DIR/instances"

usage() {
    cat << 'EOF'
Usage: ./scripts/remote.sh <instance> <command> [args...]

Commands:
  pairing list                  List pending pairing requests
  pairing approve <code>        Approve a pairing request
  pairing reject <code>         Reject a pairing request
  status                        Check gateway status
  restart                       Restart gateway
  logs [lines]                  Show recent logs (default: 50)
  exec <command>                Run arbitrary command

Examples:
  ./scripts/remote.sh jack pairing list
  ./scripts/remote.sh jack pairing approve 26BBYU6C
  ./scripts/remote.sh jack status
  ./scripts/remote.sh jack logs 100
EOF
    exit 1
}

[[ $# -lt 2 ]] && usage

INSTANCE="$1"
COMMAND="$2"
shift 2

# Load instance config
INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE"
if [[ ! -d "$INSTANCE_DIR" ]]; then
    echo "Error: Instance '$INSTANCE' not found in $INSTANCES_DIR"
    echo "Available instances:"
    ls -1 "$INSTANCES_DIR" 2>/dev/null || echo "  (none)"
    exit 1
fi

IP=$(cat "$INSTANCE_DIR/ip" 2>/dev/null || echo "")
SSH_KEY="$HOME/.ssh/openclaw_$INSTANCE"

if [[ -z "$IP" ]]; then
    echo "Error: No IP found for instance '$INSTANCE'"
    exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
    echo "Error: SSH key not found: $SSH_KEY"
    exit 1
fi

# SSH wrapper
remote() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$IP" \
        "su - openclaw -c '$*'"
}

case "$COMMAND" in
    pairing)
        SUBCMD="${1:-}"
        shift || true
        case "$SUBCMD" in
            list)
                remote "openclaw pairing list telegram"
                ;;
            approve)
                CODE="${1:-}"
                [[ -z "$CODE" ]] && { echo "Error: pairing approve requires <code>"; exit 1; }
                remote "openclaw pairing approve telegram $CODE"
                echo "✓ Approved pairing code $CODE on $INSTANCE"
                ;;
            reject)
                CODE="${1:-}"
                [[ -z "$CODE" ]] && { echo "Error: pairing reject requires <code>"; exit 1; }
                remote "openclaw pairing reject telegram $CODE"
                echo "✓ Rejected pairing code $CODE on $INSTANCE"
                ;;
            *)
                echo "Unknown pairing command: $SUBCMD"
                echo "Use: list, approve <code>, reject <code>"
                exit 1
                ;;
        esac
        ;;
    status)
        remote "systemctl status openclaw-gateway --no-pager" || true
        ;;
        
    # NOTE: OpenClaw uses pairing system, not manual allowedSenders
    # Use: pairing approve <code> after user messages the bot
    restart)
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$IP" \
            "systemctl restart openclaw-gateway"
        echo "✓ Restarted gateway on $INSTANCE"
        ;;
    logs)
        LINES="${1:-50}"
        remote "tail -$LINES /var/log/openclaw-setup.log" || \
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "root@$IP" \
            "journalctl -u openclaw-gateway -n $LINES --no-pager"
        ;;
    exec)
        [[ $# -eq 0 ]] && { echo "Error: exec requires a command"; exit 1; }
        remote "$*"
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
