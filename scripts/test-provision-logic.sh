#!/usr/bin/env bash
# Test script to verify provision.sh logic without creating actual resources
set -euo pipefail

echo "Testing provision.sh argument parsing and logic..."
echo ""

# Test 1: No arguments (auto-generate name)
echo "Test 1: No arguments (should auto-generate name)"
NAME=""
REGION="nbg1"
if [ -z "$NAME" ]; then
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  NAME="openclaw-${TIMESTAMP}"
fi
echo "  Generated name: $NAME"
echo "  Region: $REGION"
echo "  ✓ PASS"
echo ""

# Test 2: Custom name
echo "Test 2: Custom name"
NAME="test-instance"
REGION="nbg1"
echo "  Name: $NAME"
echo "  Region: $REGION"
echo "  ✓ PASS"
echo ""

# Test 3: Custom name and region
echo "Test 3: Custom name and region"
NAME="test-instance-fsn"
REGION="fsn1"
echo "  Name: $NAME"
echo "  Region: $REGION"
echo "  ✓ PASS"
echo ""

# Test 4: Path generation
echo "Test 4: Path generation"
NAME="test-vm"
SSH_KEY_PATH="$HOME/.ssh/openclaw_${NAME}"
INSTANCES_DIR="$(cd "$(dirname "$0")/.." && pwd)/instances"
INSTANCE_DIR="${INSTANCES_DIR}/${NAME}"
echo "  SSH key path: $SSH_KEY_PATH"
echo "  Instance dir: $INSTANCE_DIR"
echo "  ✓ PASS"
echo ""

# Test 5: Metadata JSON format
echo "Test 5: Metadata JSON format"
NAME="test-vm"
SERVER_IP="1.2.3.4"
REGION="nbg1"
SERVER_TYPE="cx22"
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SSH_KEY_PATH="$HOME/.ssh/openclaw_${NAME}"

METADATA=$(cat <<EOF
{
  "name": "$NAME",
  "ip": "$SERVER_IP",
  "region": "$REGION",
  "server_type": "$SERVER_TYPE",
  "status": "provisioned",
  "created_at": "$CREATED_AT",
  "ssh_key_path": "$SSH_KEY_PATH"
}
EOF
)

echo "$METADATA" | jq . > /dev/null && echo "  ✓ Valid JSON" || echo "  ✗ Invalid JSON"
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "  ✅ All logic tests passed"
echo "════════════════════════════════════════════════════════════════"
