#!/usr/bin/env bats
# Tests for scripts/diagnose-remote.sh

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq
  ensure_python3

  create_mock_instance "jack" "10.0.0.1" "root"
  copy_script "diagnose-remote.sh"

  SCRIPT="$FAKE_PROJECT/scripts/diagnose-remote.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "diagnose-remote: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "diagnose-remote: shows usage with --help" {
  run "$SCRIPT" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"14 checks"* ]]
}

# ── Self-diagnosis ──────────────────────────────────────────────────────────

@test "diagnose-remote: self delegates to proactive-amcp diagnose" {
  create_mock_proactive_amcp
  run "$SCRIPT" self
  [ "$status" -eq 0 ]
  [[ "$output" == *"checks_passed"* ]]
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "diagnose-remote: reports error when SSH fails" {
  create_mock_ssh_fail
  run "$SCRIPT" jack --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.checks.ssh.status == "error"'
}

@test "diagnose-remote: human-readable output on SSH failure" {
  create_mock_ssh_fail
  run "$SCRIPT" jack
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]] || [[ "$output" == *"Cannot reach"* ]]
}

# ── Successful diagnosis with full probe ────────────────────────────────────

@test "diagnose-remote: parses full probe output in JSON mode" {
  # Mock SSH to return a full probe response
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"

# First call is SSH connectivity check
if echo "$*" | grep -q "echo ok"; then
  echo "ok"
  exit 0
fi

# Second call is the batch probe
if echo "$*" | grep -q "bash -s"; then
  cat << 'EOPROBE'
---CLAW_CHECK---gateway_process
ok:18789
---CLAW_CHECK---health_endpoint
ok:port=18789:52ms
---CLAW_CHECK---sessions
ok:3_sessions
---CLAW_CHECK---config_valid
ok:valid
---CLAW_CHECK---disk
67
---CLAW_CHECK---memory
55:45
---CLAW_CHECK---claude_cli
ok:1.0.45
---CLAW_CHECK---claude_auth
ok:active:openclaw
---CLAW_CHECK---api_key
200:sk-ant-a01***
---CLAW_CHECK---user_mismatch
root:root
---CLAW_CHECK---amcp_identity
ok:BIJKlmnop123456789
---CLAW_CHECK---amcp_config
ok:all_present
---CLAW_CHECK---last_checkpoint
bafkreitest123456789:2h
EOPROBE
  exit 0
fi

echo "ok"
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]

  # Verify JSON structure
  echo "$output" | jq -e '.instance == "jack"'
  echo "$output" | jq -e '.checks_passed >= 10'
  echo "$output" | jq -e '.checks_failed == 0'

  # Spot-check individual checks
  echo "$output" | jq -e '.checks.ssh.status == "ok"'
  echo "$output" | jq -e '.checks.gateway.status == "ok"'
  echo "$output" | jq -e '.checks.health.status == "ok"'
  echo "$output" | jq -e '.checks.amcp_identity.status == "ok"'
  echo "$output" | jq -e '.checks.api_key.status == "ok"'
  echo "$output" | jq -e '.checks.checkpoint.status == "ok"'
}

@test "diagnose-remote: human-readable output shows all categories" {
  # Same mock as above
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
if echo "$*" | grep -q "bash -s"; then
  cat << 'EOPROBE'
---CLAW_CHECK---gateway_process
ok:18789
---CLAW_CHECK---health_endpoint
ok:port=18789:52ms
---CLAW_CHECK---sessions
ok:3_sessions
---CLAW_CHECK---config_valid
ok:valid
---CLAW_CHECK---disk
67
---CLAW_CHECK---memory
55:45
---CLAW_CHECK---claude_cli
ok:1.0.45
---CLAW_CHECK---claude_auth
ok:active:openclaw
---CLAW_CHECK---api_key
200:sk-ant-a01***
---CLAW_CHECK---user_mismatch
root:root
---CLAW_CHECK---amcp_identity
ok:BIJKlmnop123456789
---CLAW_CHECK---amcp_config
ok:all_present
---CLAW_CHECK---last_checkpoint
bafkreitest123456789:2h
EOPROBE
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]

  # Check for section headers
  [[ "$output" == *"Connectivity:"* ]]
  [[ "$output" == *"Authentication:"* ]]
  [[ "$output" == *"AMCP:"* ]]
  [[ "$output" == *"System:"* ]]
  [[ "$output" == *"Summary:"* ]]
}

# ── Error detection ─────────────────────────────────────────────────────────

@test "diagnose-remote: detects gateway not running" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
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
80
---CLAW_CHECK---memory
60:40
---CLAW_CHECK---claude_cli
warn:not_installed
---CLAW_CHECK---claude_auth
warn:no_credentials:root
---CLAW_CHECK---api_key
missing:
---CLAW_CHECK---user_mismatch
root:root
---CLAW_CHECK---amcp_identity
error:no_identity
---CLAW_CHECK---amcp_config
warn:no_pamcp_or_config
---CLAW_CHECK---last_checkpoint
none:
EOPROBE
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.checks_failed >= 3'
  echo "$output" | jq -e '.checks.gateway.status == "error"'
  echo "$output" | jq -e '.checks.health.status == "error"'
  echo "$output" | jq -e '.checks.amcp_identity.status == "error"'
  echo "$output" | jq -e '.checks.api_key.status == "error"'
  echo "$output" | jq -e '.errors | length >= 3'
}

@test "diagnose-remote: detects fake AMCP identity" {
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
ok:1_sessions
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
error:fake:sha256:abc123
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

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.amcp_identity.status == "error"'
  echo "$output" | jq -e '.checks.amcp_identity.detail | test("Fake")'
}

@test "diagnose-remote: detects stale checkpoint (>24h)" {
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
ok:1_sessions
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
bafkreitest:48h
EOPROBE
  exit 0
fi
echo "ok"; exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.checkpoint.status == "warn"'
  echo "$output" | jq -e '.checks.checkpoint.detail | test("stale")'
}

@test "diagnose-remote: detects invalid API key (401)" {
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
ok:1_sessions
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
401:sk-ant-bad***
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

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.api_key.status == "error"'
  echo "$output" | jq -e '.checks.api_key.detail | test("Invalid")'
}

@test "diagnose-remote: detects user mismatch" {
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
ok:1_sessions
---CLAW_CHECK---config_valid
ok:valid
---CLAW_CHECK---disk
70
---CLAW_CHECK---memory
60:40
---CLAW_CHECK---claude_cli
ok:1.0.45
---CLAW_CHECK---claude_auth
ok:active:openclaw
---CLAW_CHECK---api_key
200:sk-ant-test***
---CLAW_CHECK---user_mismatch
root:openclaw
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

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.user_mismatch.status == "warn"'
  echo "$output" | jq -e '.checks.user_mismatch.detail | test("service runs as")'
}

@test "diagnose-remote: nonexistent instance fails" {
  run "$SCRIPT" nonexistent --json
  [ "$status" -ne 0 ]
}

@test "diagnose-remote: disk space warning at <50%" {
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
35
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

  run "$SCRIPT" jack --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.checks.disk.status == "warn"'
}
