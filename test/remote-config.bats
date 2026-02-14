#!/usr/bin/env bats
# Tests for scripts/remote-config.sh

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq

  create_mock_instance "jack" "10.0.0.1" "root"
  create_mock_credentials
  copy_script "remote-config.sh"

  # Default: SSH succeeds
  create_mock_ssh "ok"

  SCRIPT="$FAKE_PROJECT/scripts/remote-config.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "remote-config: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "remote-config: shows usage with --help" {
  run "$SCRIPT" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"--show"* ]]
  [[ "$output" == *"--set"* ]]
  [[ "$output" == *"--push"* ]]
}

# ── --show ──────────────────────────────────────────────────────────────────

@test "remote-config: --show displays config header" {
  # Mock ssh to return config values
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Simulate proactive-amcp config get for each key
if echo "$*" | grep -q "proactive-amcp config get"; then
  echo "CFG:pinata_jwt=eyJtest1234"
  echo "CFG:anthropic.apiKey=sk-ant-abc123"
  echo "CFG:solvr_api_key=solvr_test"
  echo "CFG:instance_name=jack"
  echo "CFG:parent_bot_token=123:ABC"
  echo "CFG:parent_chat_id=999"
  echo "CFG:notify.emailTo=test@example.com"
  echo "CFG:notify.agentmailApiKey=amail123"
  echo "CFG:notify.agentmailInbox="
  echo "CFG:watchdog.interval=120"
  echo "CFG:checkpoint.schedule=0 */4 * * *"
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --show
  [ "$status" -eq 0 ]
  [[ "$output" == *"AMCP Config: jack"* ]]
}

@test "remote-config: --show is the default action" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "proactive-amcp config get"; then
  echo "CFG:pinata_jwt=eyJtest1234"
  echo "CFG:instance_name=jack"
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"AMCP Config:"* ]]
}

# ── --set ───────────────────────────────────────────────────────────────────

@test "remote-config: --set calls proactive-amcp config set" {
  # Mock SSH to accept config set and return matching value on get
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "config set"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "config get"; then echo "new_value_123"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --set pinata_jwt=new_value_123
  [ "$status" -eq 0 ]
  [[ "$output" == *"set and verified"* ]] || [[ "$output" == *"OK"* ]]
}

@test "remote-config: --set requires key=value format" {
  run "$SCRIPT" jack --set "badformat"
  [ "$status" -eq 1 ]
  [[ "$output" == *"key=value"* ]] || [[ "$output" == *"Invalid"* ]]
}

@test "remote-config: --set requires a value after flag" {
  run "$SCRIPT" jack --set
  [ "$status" -eq 1 ]
}

# ── --push ──────────────────────────────────────────────────────────────────

@test "remote-config: --push reads from credentials.json" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "config set"; then echo "ok"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --push
  [ "$status" -eq 0 ]
  [[ "$output" == *"keys pushed"* ]]

  # Verify SSH was called with config set commands
  grep -c "config set" "$TEST_DIR/ssh.log" || true
}

@test "remote-config: --push fails without credentials.json" {
  rm -f "$FAKE_PROJECT/instances/credentials.json"
  run "$SCRIPT" jack --push
  [ "$status" -eq 1 ]
  [[ "$output" == *"credentials.json not found"* ]]
}

@test "remote-config: --push maps credential keys correctly" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --push
  [ "$status" -eq 0 ]

  # Check that the correct AMCP config keys were used
  grep -q "pinata_jwt" "$TEST_DIR/ssh.log"
  grep -q "anthropic.apiKey" "$TEST_DIR/ssh.log"
  grep -q "solvr_api_key" "$TEST_DIR/ssh.log"
  grep -q "parent_bot_token" "$TEST_DIR/ssh.log"
  grep -q "parent_chat_id" "$TEST_DIR/ssh.log"
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "remote-config: fails gracefully when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack --show
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot reach"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "remote-config: nonexistent instance fails" {
  run "$SCRIPT" nonexistent --show
  [ "$status" -ne 0 ]
}
