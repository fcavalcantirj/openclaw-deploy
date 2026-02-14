#!/usr/bin/env bats
# Tests for scripts/setup-amcp.sh

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELPER="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/test_helper.sh"

setup() {
  source "$HELPER"
  setup_test_env
  ensure_jq

  create_mock_instance "jack" "10.0.0.1" "root"
  create_mock_credentials
  copy_script "setup-amcp.sh"
  copy_script "remote-config.sh"  # setup-amcp calls remote-config --push

  SCRIPT="$FAKE_PROJECT/scripts/setup-amcp.sh"
}

teardown() {
  teardown_test_env
}

# ── Usage / argument tests ──────────────────────────────────────────────────

@test "setup-amcp: shows usage with no args" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "setup-amcp: shows usage with --help" {
  run "$SCRIPT" --help
  [ "$status" -eq 1 ]
  [[ "$output" == *"--force"* ]]
  [[ "$output" == *"--dry-run"* ]]
}

# ── SSH failure ─────────────────────────────────────────────────────────────

@test "setup-amcp: fails when SSH unreachable" {
  create_mock_ssh_fail
  run "$SCRIPT" jack
  [ "$status" -ne 0 ]
  [[ "$output" == *"Cannot reach"* ]] || [[ "$output" == *"ERROR"* ]]
}

# ── Dry run ─────────────────────────────────────────────────────────────────

@test "setup-amcp: --dry-run shows what would be done" {
  # Mock SSH to return probe data
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
# Probe: everything missing
cat << 'EOPROBE'
npm:ok
amcp:missing
pamcp:missing
identity:missing
watchdog:inactive
EOPROBE
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dry run"* ]]
  [[ "$output" == *"[install] amcp CLI"* ]]
  [[ "$output" == *"[install] proactive-amcp"* ]]
  [[ "$output" == *"[create] AMCP identity"* ]]
  [[ "$output" == *"[push] Config"* ]]
  [[ "$output" == *"[install] Watchdog"* ]]
}

@test "setup-amcp: --dry-run shows skip for existing components" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
cat << 'EOPROBE'
npm:ok
amcp:ok:1.2.3
pamcp:bin:v0.7.0
identity:exists:BIJKlmnop123
watchdog:active
EOPROBE
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[skip] amcp CLI"* ]]
  [[ "$output" == *"[skip] proactive-amcp"* ]]
  [[ "$output" == *"[skip] AMCP identity"* ]]
  [[ "$output" == *"[skip] Watchdog"* ]]
}

@test "setup-amcp: --dry-run --force shows recreate for identity" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
cat << 'EOPROBE'
npm:ok
amcp:ok:1.2.3
pamcp:bin:v0.7.0
identity:exists:BIJKlmnop123
watchdog:active
EOPROBE
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack --dry-run --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"[recreate] AMCP identity"* ]]
}

# ── Full bootstrap ──────────────────────────────────────────────────────────

@test "setup-amcp: full bootstrap with all missing components" {
  # Multi-phase SSH mock — order matters: more specific patterns first
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"

# SSH connectivity check (ssh_check sends "echo ok")
if echo "$CMD" | grep -q '"echo ok"' || [[ "$CMD" == *"echo ok"* && "$CMD" != *"npm"* && "$CMD" != *"amcp"* && "$CMD" != *"config"* ]]; then
  echo "ok"; exit 0
fi

# Probe — matches the bash -c with npm/amcp/pamcp checks
if echo "$CMD" | grep -q "command -v npm"; then
  cat << 'EOPROBE'
npm:ok
amcp:missing
pamcp:missing
identity:missing
watchdog:inactive
EOPROBE
  exit 0
fi

# amcp CLI install
if echo "$CMD" | grep -q "npm install -g @amcp/cli"; then
  echo "INSTALL_OK"
  exit 0
fi

# Identity creation (must come before generic proactive-amcp match)
if echo "$CMD" | grep -q "amcp identity create\|openssl rand"; then
  echo "SEED:abc123def456"
  echo "CREATE_DONE"
  echo "AID:BIJKlmnopNewIdentity"
  exit 0
fi

# Watchdog install (must come before generic proactive-amcp match)
if echo "$CMD" | grep -q "proactive-amcp install"; then
  echo "INSTALL_OK"
  exit 0
fi

# Checkpoint (must come before generic proactive-amcp match)
if echo "$CMD" | grep -q "proactive-amcp checkpoint"; then
  echo "Checkpoint created: bafkreifirstcheckpoint"
  exit 0
fi

# Config set (from remote-config --push)
if echo "$CMD" | grep -q "config set\|config get"; then
  echo "ok"
  exit 0
fi

# proactive-amcp install via clawhub/npm
if echo "$CMD" | grep -q "clawhub install\|proactive-amcp"; then
  echo "ok:npm"
  exit 0
fi

echo "ok"
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"
  create_mock_scp

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"AMCP setup complete"* ]]

  # Verify metadata was updated
  local meta="$FAKE_PROJECT/instances/jack/metadata.json"
  jq -e '.amcp_status == "bootstrapped"' "$meta"
}

@test "setup-amcp: skips already-installed components" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
CMD="$*"

if echo "$CMD" | grep -q "echo ok"; then echo "ok"; exit 0; fi

# Probe: everything present
if echo "$CMD" | grep -q "npm:"; then
  cat << 'EOPROBE'
npm:ok
amcp:ok:1.2.3
pamcp:bin:v0.7.0
identity:exists:BIJKlmnop123
watchdog:active
EOPROBE
  exit 0
fi

# Config set
if echo "$CMD" | grep -q "config set"; then echo "ok"; exit 0; fi

# Checkpoint
if echo "$CMD" | grep -q "proactive-amcp checkpoint"; then
  echo "Checkpoint created: bafkreiskiptest"
  exit 0
fi

echo "ok"
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already installed"* ]]
  [[ "$output" == *"Identity exists"* ]]
  [[ "$output" == *"Already active"* ]]
}

@test "setup-amcp: fails when npm not available and components missing" {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
if echo "$*" | grep -q "echo ok"; then echo "ok"; exit 0; fi
cat << 'EOPROBE'
npm:missing
amcp:missing
pamcp:missing
identity:missing
watchdog:inactive
EOPROBE
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"

  run "$SCRIPT" jack
  [ "$status" -ne 0 ]
  [[ "$output" == *"npm not available"* ]]
}

@test "setup-amcp: nonexistent instance fails" {
  run "$SCRIPT" nonexistent
  [ "$status" -ne 0 ]
}
