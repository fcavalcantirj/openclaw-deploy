#!/usr/bin/env bats
# Tests for scripts/fix-remote.sh

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq
  ensure_python3

  create_mock_instance "jack" "10.0.0.1" "root"
  create_mock_credentials
  copy_script "fix-remote.sh"
  copy_script "diagnose-remote.sh"

  SCRIPT="$FAKE_PROJECT/scripts/fix-remote.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "fix-remote: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ── Healthy instance = no fix needed ────────────────────────────────────────

@test "fix-remote: exits early when instance is healthy" {
  # Mock SSH to make diagnose return all-healthy
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "bash -s"; then
  cat << 'EOPROBE'
---CLAW_CHECK---gateway_process
ok:18789
---CLAW_CHECK---health_endpoint
ok:port=18789:30ms
---CLAW_CHECK---sessions
ok:0_sessions
---CLAW_CHECK---config_valid
ok:valid
---CLAW_CHECK---disk
70
---CLAW_CHECK---memory
60:40
---CLAW_CHECK---claude_cli
ok:1.0.45
---CLAW_CHECK---claude_auth
ok:active:root
---CLAW_CHECK---api_key
200:sk-ant-test***
---CLAW_CHECK---user_mismatch
root:root
---CLAW_CHECK---amcp_identity
ok:BIJKlmnop123456789
---CLAW_CHECK---amcp_config
ok:all_present
---CLAW_CHECK---last_checkpoint
bafkreitest:1h
EOPROBE
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]] || [[ "$output" == *"No issues"* ]]
}

# ── Fix flow with errors ────────────────────────────────────────────────────

@test "fix-remote: runs Claude Code when errors found" {
  # First SSH calls: diagnose returns errors
  # Later SSH calls: fix sequence
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"

if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi

# Diagnose probe
if echo "$*" | grep -q "bash -s"; then
  cat << 'EOPROBE'
---CLAW_CHECK---gateway_process
error:not_running
---CLAW_CHECK---health_endpoint
error:no_health_endpoint
---CLAW_CHECK---sessions
ok:0_sessions
---CLAW_CHECK---config_valid
ok:valid
---CLAW_CHECK---disk
70
---CLAW_CHECK---memory
60:40
---CLAW_CHECK---claude_cli
ok:1.0.45
---CLAW_CHECK---claude_auth
ok:active:root
---CLAW_CHECK---api_key
200:sk-ant-test***
---CLAW_CHECK---user_mismatch
root:root
---CLAW_CHECK---amcp_identity
ok:BIJKlmnop123
---CLAW_CHECK---amcp_config
ok:all_present
---CLAW_CHECK---last_checkpoint
bafkreitest:1h
EOPROBE
  exit 0
fi

# Solvr key fetch
if echo "$*" | grep -q "config get solvr"; then
  echo "solvr_test_key"
  exit 0
fi

# Claude Code fix session
if echo "$*" | grep -q "claude"; then
  echo '{"fixed": 2, "escalated": 0, "fixes": [{"error": "gateway", "action": "restart"}]}'
  exit 0
fi

echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"
  create_mock_scp
  create_mock_curl

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]

  # Verify Claude Code was invoked
  grep -q "claude" "$TEST_DIR/ssh.log"
}

# ── Nonexistent instance ────────────────────────────────────────────────────

@test "fix-remote: nonexistent instance fails" {
  run "$SCRIPT" nonexistent
  [ "$status" -ne 0 ]
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "fix-remote: fails when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack
  [ "$status" -ne 0 ]
}
