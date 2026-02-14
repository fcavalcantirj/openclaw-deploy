#!/usr/bin/env bats
# Tests for scripts/auth.sh — Show/switch auth mode on a child instance

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq

  create_mock_instance "jack" "10.0.0.1" "root"
  copy_script "auth.sh"

  # Default: SSH succeeds
  create_mock_ssh "ok"

  SCRIPT="$FAKE_PROJECT/scripts/auth.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "auth: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "auth: shows usage with --help" {
  run "$SCRIPT" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"--mode"* ]]
}

@test "auth: rejects invalid --mode value" {
  run "$SCRIPT" jack --mode banana
  [ "$status" -eq 1 ]
  [[ "$output" == *"oauth"* ]] || [[ "$output" == *"apikey"* ]]
}

@test "auth: nonexistent instance fails" {
  run "$SCRIPT" nonexistent
  [ "$status" -ne 0 ]
}

# ── Show mode (default) ────────────────────────────────────────────────────

@test "auth: show displays active auth profile" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
# SSH connectivity check
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Show mode: read auth state
if echo "$CMD" | grep -q "python3 -c"; then
  echo '{"active_profile":"anthropic:token","order":["token"],"oauth_creds":false,"oauth_expiry":null}'
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"anthropic:token"* ]]
}

@test "auth: show is the default action (no --mode)" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then
  echo '{"active_profile":"anthropic:token","order":["token"],"oauth_creds":false,"oauth_expiry":null}'
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auth"* ]]
}

@test "auth: show reports OAuth creds when present" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then
  echo '{"active_profile":"anthropic:oauth","order":["oauth","token"],"oauth_creds":true,"oauth_expiry":"2026-03-01T00:00:00Z"}'
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"oauth"* ]]
  [[ "$output" == *"2026"* ]]
}

# ── Switch to OAuth (--mode oauth) ──────────────────────────────────────────

@test "auth: --mode oauth patches auth-profiles and sessions" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Check for credentials file existence
if echo "$CMD" | grep -q "test -f.*credentials"; then echo "exists"; exit 0; fi
# The python3 patch command
if echo "$CMD" | grep -q "python3 -c"; then echo "ok"; exit 0; fi
# Gateway restart
if echo "$CMD" | grep -q "systemctl restart\|pkill"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl is-active"; then echo "active"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode oauth
  [ "$status" -eq 0 ]
  [[ "$output" == *"oauth"* ]]

  # Verify SSH was called with python3 patch
  grep -q "python3" "$TEST_DIR/ssh.log"
}

@test "auth: --mode oauth fails when credentials.json missing" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Credentials file does NOT exist
if echo "$CMD" | grep -q "test -f.*credentials"; then echo "missing"; exit 1; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode oauth
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude login"* ]] || [[ "$output" == *"credentials"* ]]
}

@test "auth: --mode oauth restarts gateway" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "test -f.*credentials"; then echo "exists"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl restart\|pkill"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl is-active"; then echo "active"; exit 0; fi
if echo "$CMD" | grep -q "journalctl"; then echo "gateway started"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode oauth
  [ "$status" -eq 0 ]

  # Verify restart happened
  grep -q "systemctl" "$TEST_DIR/ssh.log" || grep -q "pkill" "$TEST_DIR/ssh.log"
}

# ── Switch to API key (--mode apikey) ───────────────────────────────────────

@test "auth: --mode apikey patches auth-profiles and sessions" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl restart\|pkill"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl is-active"; then echo "active"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode apikey
  [ "$status" -eq 0 ]
  [[ "$output" == *"apikey"* ]] || [[ "$output" == *"token"* ]]

  # Verify SSH was called with python3 patch
  grep -q "python3" "$TEST_DIR/ssh.log"
}

@test "auth: --mode apikey does not require OAuth credentials" {
  # apikey mode should work regardless of whether credentials.json exists
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl restart\|pkill"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl is-active"; then echo "active"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode apikey
  [ "$status" -eq 0 ]
}

@test "auth: --mode apikey restarts gateway" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"
if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "python3 -c"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl restart\|pkill"; then echo "ok"; exit 0; fi
if echo "$CMD" | grep -q "systemctl is-active"; then echo "active"; exit 0; fi
if echo "$CMD" | grep -q "journalctl"; then echo "gateway started"; exit 0; fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --mode apikey
  [ "$status" -eq 0 ]

  grep -q "systemctl" "$TEST_DIR/ssh.log" || grep -q "pkill" "$TEST_DIR/ssh.log"
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "auth: fails gracefully when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot reach"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "auth: --mode oauth fails gracefully when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack --mode oauth
  [ "$status" -ne 0 ]
}
