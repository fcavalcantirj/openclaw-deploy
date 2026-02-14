#!/usr/bin/env bats
# Tests for scripts/remote-checkpoint.sh

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq

  create_mock_instance "jack" "10.0.0.1" "root"
  copy_script "remote-checkpoint.sh"

  SCRIPT="$FAKE_PROJECT/scripts/remote-checkpoint.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "remote-checkpoint: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "remote-checkpoint: shows usage with --help" {
  run "$SCRIPT" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"--full"* ]]
}

# ── Quick checkpoint ────────────────────────────────────────────────────────

@test "remote-checkpoint: runs quick checkpoint and captures CID" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
# SSH connectivity check (ssh_check calls "echo ok")
if echo "$CMD" | grep -q '"echo ok"' || echo "$CMD" | grep -qw "echo ok"; then
  echo "ok"; exit 0
fi
# Service user detection (bash -c with systemctl inside)
if echo "$CMD" | grep -q "systemctl show"; then
  echo "root"; exit 0
fi
# Checkpoint command
if echo "$CMD" | grep -q "proactive-amcp checkpoint"; then
  echo "Checkpoint created: bafkreitestcheckpointabcdef"; exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"bafkreitestcheckpointabcdef"* ]]

  # Verify metadata was updated
  local meta="$FAKE_PROJECT/instances/jack/metadata.json"
  jq -e '.last_checkpoint_cid == "bafkreitestcheckpointabcdef"' "$meta"
}

@test "remote-checkpoint: --full runs full-checkpoint" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q '"echo ok"' || echo "$CMD" | grep -qw "echo ok"; then
  echo "ok"; exit 0
fi
if echo "$CMD" | grep -q "systemctl show"; then echo "root"; exit 0; fi
if echo "$CMD" | grep -q "full-checkpoint"; then
  echo "Full checkpoint: bafkreifullcheckpointabc"
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --full
  [ "$status" -eq 0 ]
  [[ "$output" == *"bafkreifullcheckpointabc"* ]]

  # Verify the SSH log shows full-checkpoint was called
  grep -q "full-checkpoint" "$TEST_DIR/ssh.log"
}

# ── Service user detection ──────────────────────────────────────────────────

@test "remote-checkpoint: detects service user and runs as that user" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Return a different service user
if echo "$*" | grep -q "systemctl show"; then
  echo "openclaw"
  exit 0
fi
# Check that su is used
if echo "$*" | grep -q "su -"; then
  echo "Checkpoint created: bafkreiserviceuser123"
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]

  # Should see su - openclaw in the SSH log
  grep -q "su -" "$TEST_DIR/ssh.log" || grep -q "openclaw" "$TEST_DIR/ssh.log"
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "remote-checkpoint: fails when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot reach"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "remote-checkpoint: nonexistent instance fails" {
  run "$SCRIPT" nonexistent
  [ "$status" -ne 0 ]
}

# ── CID extraction fallback ────────────────────────────────────────────────

@test "remote-checkpoint: warns when CID not captured" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"

# SSH connectivity check
if [[ "$CMD" == *"echo ok"* ]] && [[ "$CMD" != *"proactive"* ]] && [[ "$CMD" != *"systemctl"* ]] && [[ "$CMD" != *"python3"* ]]; then
  echo "ok"; exit 0
fi

# Service user detection
if echo "$CMD" | grep -q "systemctl show"; then
  echo "root"; exit 0
fi

# Checkpoint: return text with no CID
if echo "$CMD" | grep -q "proactive-amcp"; then
  echo "some output without a valid cid"; exit 0
fi

# Fallback python3 CID read: return empty
if echo "$CMD" | grep -q "python3"; then
  echo ""; exit 0
fi

echo ""; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"CID not captured"* ]] || [[ "$output" == *"WARN"* ]]
}
