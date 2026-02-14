#!/bin/bash
# test_helper.sh — Shared test setup, teardown, and mocks for openclaw-deploy BATS tests
#
# Every test gets an isolated temp directory with mock instances, SSH, etc.
# No real SSH or VM contact ever happens in tests.

PROJECT_ROOT="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"

# ── Setup / Teardown ────────────────────────────────────────────────────────

setup_test_env() {
  export TEST_DIR="$(mktemp -d)"
  export HOME="$TEST_DIR/home"
  export MOCK_BIN="$TEST_DIR/mock-bin"

  mkdir -p "$HOME" "$MOCK_BIN"

  # Mock bin at front of PATH
  export ORIGINAL_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"

  # Set up a fake project root with instances dir
  export FAKE_PROJECT="$TEST_DIR/project"
  mkdir -p "$FAKE_PROJECT/scripts/lib"
  mkdir -p "$FAKE_PROJECT/instances"
  mkdir -p "$FAKE_PROJECT/templates"

  # Copy common.sh (real one — it's the foundation)
  cp "$PROJECT_ROOT/scripts/lib/common.sh" "$FAKE_PROJECT/scripts/lib/common.sh"

  # Create a minimal fix-prompt template
  cat > "$FAKE_PROJECT/templates/fix-prompt.md" << 'EOTEMPLATE'
Fix issues on {{INSTANCE_NAME}}.
{{DIAGNOSE_OUTPUT}}
{{SOLVR_FIX_SECTION}}
{{ESCALATION_SECTION}}
EOTEMPLATE
}

teardown_test_env() {
  if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
    rm -rf "$TEST_DIR"
  fi
}

# ── Instance helpers ─────────────────────────────────────────────────────────

# Create a mock instance with metadata
# Usage: create_mock_instance "jack" [ip] [ssh_user]
create_mock_instance() {
  local name="${1:-testbot}"
  local ip="${2:-10.0.0.1}"
  local ssh_user="${3:-root}"
  local instance_dir="$FAKE_PROJECT/instances/$name"
  mkdir -p "$instance_dir"

  # Create a fake SSH key
  echo "fake-ssh-key" > "$instance_dir/ssh_key"
  chmod 600 "$instance_dir/ssh_key"

  cat > "$instance_dir/metadata.json" << EOMETA
{
  "name": "$name",
  "ip": "$ip",
  "ssh_key_path": "$instance_dir/ssh_key",
  "ssh_user": "$ssh_user",
  "region": "nbg1",
  "status": "operational",
  "gateway_token": "test-gw-token-123",
  "parent_telegram_token": "123456:AABBCC",
  "parent_chat_id": "999888",
  "parent_email": "test@example.com"
}
EOMETA
}

# Create mock credentials.json
create_mock_credentials() {
  cat > "$FAKE_PROJECT/instances/credentials.json" << 'EOCREDS'
{
  "anthropic_api_key": "sk-ant-test-key-12345",
  "pinata_jwt": "eyJhbGciOiJIUzI1NiJ9.test_pinata",
  "solvr_api_key": "solvr_test_key_abc",
  "parent_telegram_bot_token": "123456:TESTBOT",
  "parent_telegram_chat_id": "999888",
  "agentmail_api_key": "agentmail_test_key",
  "notify_email": "test@example.com"
}
EOCREDS
}

# ── SSH mocking ──────────────────────────────────────────────────────────────

# Mock ssh that records calls and returns configurable output
# Usage: create_mock_ssh "output string"
create_mock_ssh() {
  local output="${1:-ok}"
  cat > "$MOCK_BIN/ssh" << EOSSH
#!/bin/bash
echo "ssh \$*" >> "\${TEST_DIR}/ssh.log"
echo "$output"
exit 0
EOSSH
  chmod +x "$MOCK_BIN/ssh"
}

# Mock ssh that fails (simulates unreachable host)
create_mock_ssh_fail() {
  cat > "$MOCK_BIN/ssh" << 'EOSSH'
#!/bin/bash
echo "ssh $*" >> "${TEST_DIR}/ssh.log"
exit 255
EOSSH
  chmod +x "$MOCK_BIN/ssh"
}

# Mock ssh that returns different output based on command content
# Usage: create_mock_ssh_smart "pattern1:output1" "pattern2:output2" "default_output"
create_mock_ssh_smart() {
  local default_output="${!#}"  # last arg is default
  local args=("$@")
  unset 'args[${#args[@]}-1]'  # remove last

  {
    echo '#!/bin/bash'
    echo 'echo "ssh $*" >> "${TEST_DIR}/ssh.log"'
    echo 'CMD="$*"'
    for mapping in "${args[@]}"; do
      local pattern="${mapping%%:*}"
      local output="${mapping#*:}"
      echo "if echo \"\$CMD\" | grep -q '$pattern'; then echo '$output'; exit 0; fi"
    done
    echo "echo '$default_output'"
    echo 'exit 0'
  } > "$MOCK_BIN/ssh"
  chmod +x "$MOCK_BIN/ssh"
}

# Mock scp that always succeeds
create_mock_scp() {
  cat > "$MOCK_BIN/scp" << 'EOSCP'
#!/bin/bash
echo "scp $*" >> "${TEST_DIR}/scp.log"
exit 0
EOSCP
  chmod +x "$MOCK_BIN/scp"
}

# ── Other mocks ──────────────────────────────────────────────────────────────

# Mock jq (use real jq, just ensure it exists)
ensure_jq() {
  if ! command -v jq &>/dev/null; then
    echo "jq required for tests" >&2
    return 1
  fi
}

# Mock curl
create_mock_curl() {
  local status="${1:-200}"
  local body="${2:-ok}"
  cat > "$MOCK_BIN/curl" << EOCURL
#!/bin/bash
echo "curl \$*" >> "\${TEST_DIR}/curl.log"
if echo "\$*" | grep -q "\-w.*http_code"; then
  echo "$status"
else
  echo "$body"
fi
exit 0
EOCURL
  chmod +x "$MOCK_BIN/curl"
}

create_mock_curl_fail() {
  cat > "$MOCK_BIN/curl" << 'EOCURL'
#!/bin/bash
echo "curl $*" >> "${TEST_DIR}/curl.log"
exit 1
EOCURL
  chmod +x "$MOCK_BIN/curl"
}

# Mock proactive-amcp
create_mock_proactive_amcp() {
  local config_response="${1:-test_value}"
  cat > "$MOCK_BIN/proactive-amcp" << EOPAMCP
#!/bin/bash
echo "proactive-amcp \$*" >> "\${TEST_DIR}/pamcp.log"
if [[ "\$1" == "config" && "\$2" == "get" ]]; then
  echo "$config_response"
elif [[ "\$1" == "config" && "\$2" == "set" ]]; then
  echo "ok"
elif [[ "\$1" == "diagnose" ]]; then
  echo '{"checks_passed":6,"checks_failed":0,"checks":{},"errors":[]}'
elif [[ "\$1" == "checkpoint" || "\$1" == "full-checkpoint" ]]; then
  echo "Checkpoint created: bafkreitest1234567890abcdef"
elif [[ "\$1" == "install" ]]; then
  echo "Watchdog installed"
fi
exit 0
EOPAMCP
  chmod +x "$MOCK_BIN/proactive-amcp"
}

# Mock claude CLI
create_mock_claude() {
  local output="${1:-{\"fixed\":1,\"escalated\":0}}"
  cat > "$MOCK_BIN/claude" << EOCLAUDE
#!/bin/bash
echo "claude \$*" >> "\${TEST_DIR}/claude.log"
echo "$output"
exit 0
EOCLAUDE
  chmod +x "$MOCK_BIN/claude"
}

# Mock python3 (usually real but ensure it's available)
ensure_python3() {
  if ! command -v python3 &>/dev/null; then
    echo "python3 required for tests" >&2
    return 1
  fi
}

# ── Script copy helpers ──────────────────────────────────────────────────────

# Copy a script into the fake project and make it source from the right place
copy_script() {
  local script_name="$1"
  local src="$PROJECT_ROOT/scripts/$script_name"
  local dst="$FAKE_PROJECT/scripts/$script_name"
  cp "$src" "$dst"
  chmod +x "$dst"
}
