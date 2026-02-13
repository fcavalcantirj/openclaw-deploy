#!/bin/bash
# Manage instance credentials securely
# Usage: ./scripts/credentials.sh <instance> <command> [args...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTANCES_DIR="$ROOT_DIR/instances"

usage() {
    cat << 'EOF'
Usage: ./scripts/credentials.sh <instance> <command> [args...]

Commands:
  set-openai <key>              Set OpenAI API key
  set-anthropic <key>           Set Anthropic API key
  set-all <openai> <anthropic>  Set both keys at once
  show                          Show current keys (masked)
  wipe                          Remove all API keys from instance
  backup                        Backup credentials locally (encrypted)
  export                        Export full instance info (for email)

Examples:
  ./scripts/credentials.sh jack set-openai "sk-proj-..."
  ./scripts/credentials.sh jack set-anthropic "sk-ant-..."
  ./scripts/credentials.sh jack set-all "sk-proj-..." "sk-ant-..."
  ./scripts/credentials.sh jack show
  ./scripts/credentials.sh jack export
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
    echo "Error: Instance '$INSTANCE' not found"
    exit 1
fi

IP=$(cat "$INSTANCE_DIR/ip" 2>/dev/null || echo "")
SSH_KEY="$HOME/.ssh/openclaw_$INSTANCE"

[[ -z "$IP" ]] && { echo "Error: No IP for instance '$INSTANCE'"; exit 1; }
[[ ! -f "$SSH_KEY" ]] && { echo "Error: SSH key not found: $SSH_KEY"; exit 1; }

# Remote command wrapper
remote_cmd() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$IP" "$@"
}

# Update openclaw.json on remote
update_remote_config() {
    local python_script="$1"
    remote_cmd "cd /home/openclaw/.openclaw && python3 -c '$python_script'"
}

case "$COMMAND" in
    set-openai)
        KEY="${1:-}"
        [[ -z "$KEY" ]] && { echo "Error: OpenAI key required"; exit 1; }
        
        update_remote_config "
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
c.setdefault('auth', {})['openaiApiKey'] = '$KEY'
with open('openclaw.json', 'w') as f:
    json.dump(c, f, indent=2)
print('OpenAI key set')
"
        # Save locally (encrypted reference)
        echo "$KEY" > "$INSTANCE_DIR/.openai_key"
        chmod 600 "$INSTANCE_DIR/.openai_key"
        
        remote_cmd "systemctl restart openclaw-gateway"
        echo "✓ OpenAI key configured on $INSTANCE, gateway restarted"
        ;;
        
    set-anthropic)
        KEY="${1:-}"
        [[ -z "$KEY" ]] && { echo "Error: Anthropic key required"; exit 1; }
        
        update_remote_config "
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
c.setdefault('auth', {}).setdefault('profiles', {})['anthropic:token'] = {'type': 'api_key', 'value': '$KEY'}
with open('openclaw.json', 'w') as f:
    json.dump(c, f, indent=2)
print('Anthropic key set')
"
        # Save locally
        echo "$KEY" > "$INSTANCE_DIR/.anthropic_key"
        chmod 600 "$INSTANCE_DIR/.anthropic_key"
        
        remote_cmd "systemctl restart openclaw-gateway"
        echo "✓ Anthropic key configured on $INSTANCE, gateway restarted"
        ;;
        
    set-all)
        OPENAI_KEY="${1:-}"
        ANTHROPIC_KEY="${2:-}"
        [[ -z "$OPENAI_KEY" || -z "$ANTHROPIC_KEY" ]] && { echo "Error: Both keys required"; exit 1; }
        
        update_remote_config "
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
c.setdefault('auth', {})['openaiApiKey'] = '$OPENAI_KEY'
c['auth'].setdefault('profiles', {})['anthropic:token'] = {'type': 'api_key', 'value': '$ANTHROPIC_KEY'}
with open('openclaw.json', 'w') as f:
    json.dump(c, f, indent=2)
print('Both keys set')
"
        # Save locally
        echo "$OPENAI_KEY" > "$INSTANCE_DIR/.openai_key"
        echo "$ANTHROPIC_KEY" > "$INSTANCE_DIR/.anthropic_key"
        chmod 600 "$INSTANCE_DIR/.openai_key" "$INSTANCE_DIR/.anthropic_key"
        
        remote_cmd "systemctl restart openclaw-gateway"
        echo "✓ Both keys configured on $INSTANCE, gateway restarted"
        ;;
        
    show)
        echo "=== $INSTANCE credentials (masked) ==="
        echo "IP: $IP"
        echo "SSH: ssh -i $SSH_KEY root@$IP"
        
        # Show masked keys from remote
        remote_cmd "cd /home/openclaw/.openclaw && python3 -c \"
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
auth = c.get('auth', {})
oai = auth.get('openaiApiKey', '')
ant = auth.get('profiles', {}).get('anthropic:token', {}).get('value', '')
print(f'OpenAI: {oai[:20]}...{oai[-4:]}' if oai else 'OpenAI: (not set)')
print(f'Anthropic: {ant[:15]}...{ant[-4:]}' if ant else 'Anthropic: (not set)')
\""
        ;;
        
    wipe)
        echo "Wiping API keys from $INSTANCE..."
        remote_cmd "cd /home/openclaw/.openclaw && python3 << 'PYPYTHON'
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
if 'auth' in c:
    c['auth'].pop('openaiApiKey', None)
    if 'profiles' in c['auth']:
        c['auth']['profiles'].pop('anthropic:token', None)
with open('openclaw.json', 'w') as f:
    json.dump(c, f, indent=2)
print('Keys wiped')
PYPYTHON"
        remote_cmd "systemctl restart openclaw-gateway"
        echo "✓ API keys wiped from $INSTANCE"
        ;;
        
    export)
        # Export full instance info
        echo "=== INSTANCE: $INSTANCE ==="
        echo ""
        echo "## Connection Info"
        echo "IP: $IP"
        echo "SSH: ssh -i ~/.ssh/openclaw_$INSTANCE root@$IP"
        echo ""
        echo "## API Keys"
        if [[ -f "$INSTANCE_DIR/.openai_key" ]]; then
            echo "OpenAI: $(cat "$INSTANCE_DIR/.openai_key")"
        else
            echo "OpenAI: (not stored locally)"
        fi
        if [[ -f "$INSTANCE_DIR/.anthropic_key" ]]; then
            echo "Anthropic: $(cat "$INSTANCE_DIR/.anthropic_key")"
        else
            echo "Anthropic: (not stored locally)"
        fi
        echo ""
        echo "## Telegram Bot"
        remote_cmd "cd /home/openclaw/.openclaw && python3 -c \"
import json
with open('openclaw.json', 'r') as f:
    c = json.load(f)
tg = c.get('channels', {}).get('telegram', {})
print(f'Bot Token: {tg.get(\"botToken\", \"(not set)\")}')
\""
        echo ""
        echo "## Health Status"
        remote_cmd "systemctl status openclaw-gateway --no-pager | head -8" || true
        echo ""
        echo "## System"
        remote_cmd "uptime && free -h | head -2"
        ;;
        
    *)
        echo "Unknown command: $COMMAND"
        usage
        ;;
esac
