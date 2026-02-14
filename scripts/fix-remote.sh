#!/usr/bin/env bash
# =============================================================================
# fix-remote.sh — Auto-fix issues on a child instance via Claude Code
# =============================================================================
# Usage: ./scripts/fix-remote.sh NAME
#
# Runs diagnose-remote.sh, then uploads a fix prompt to the child VM and
# executes Claude Code to apply fixes. Searches Solvr for known solutions,
# escalates to parent Telegram/email after 3 failures.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
resolve_project_root

usage() {
  cat <<EOF
Usage: $(basename "$0") NAME

Auto-fix issues found by diagnose on a child instance.

Arguments:
  NAME    Instance name to fix

Flow:
  1. Runs diagnose to identify issues
  2. Searches Solvr for known solutions
  3. Uploads fix prompt, runs Claude Code on-VM
  4. Reports fixed/escalated counts
  5. Escalates to parent after 3 failures

EOF
  exit 1
}

[[ $# -lt 1 ]] && usage

INSTANCE_NAME="$1"; shift

# ── JSON extraction helper ───────────────────────────────────────────────────

extract_json() {
  python3 -c "
import sys, json
text = sys.stdin.read()
depth = 0
start = -1
for i, c in enumerate(text):
    if c == '{':
        if depth == 0:
            start = i
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            candidate = text[start:i+1]
            try:
                obj = json.loads(candidate)
                print(json.dumps(obj))
                sys.exit(0)
            except json.JSONDecodeError:
                start = -1
print('')
" 2>/dev/null
}

# ── Load instance ────────────────────────────────────────────────────────────

load_instance "$INSTANCE_NAME" || exit 1

local_ssh="ssh -i $INSTANCE_SSH_KEY $SSH_OPTS"

# ── Step 1: Run diagnose ────────────────────────────────────────────────────

echo -e "${BLUE}Step 1: Running diagnosis on $INSTANCE_NAME...${NC}" >&2
diagnose_output=$("$SCRIPT_DIR/diagnose-remote.sh" "$INSTANCE_NAME" --json 2>/dev/null)

if [[ -z "$diagnose_output" ]] || ! echo "$diagnose_output" | jq . >/dev/null 2>&1; then
  echo -e "${RED}Diagnosis failed — cannot proceed with fix${NC}" >&2
  exit 1
fi

# Check if there are any errors to fix
error_count=$(echo "$diagnose_output" | jq '.checks_failed // 0')
if [[ "$error_count" -eq 0 ]]; then
  echo -e "${GREEN}No issues found — $INSTANCE_NAME is healthy${NC}" >&2
  echo "$diagnose_output"
  exit 0
fi

echo -e "${YELLOW}Found $error_count issue(s) — attempting fixes...${NC}" >&2

# ── Step 2: Gather credentials ──────────────────────────────────────────────

solvr_key=$($local_ssh "${INSTANCE_SSH_USER}@$INSTANCE_IP" \
  "proactive-amcp config get solvr_api_key 2>/dev/null || echo ''" 2>/dev/null)
solvr_key=$(echo "$solvr_key" | tr -d '[:space:]')

credentials_file="$INSTANCES_DIR/credentials.json"
anthropic_key=""
if [[ -f "$credentials_file" ]]; then
  anthropic_key=$(jq -r '.anthropic_api_key // empty' "$credentials_file")
fi
if [[ -z "$anthropic_key" ]]; then
  anthropic_key="${ANTHROPIC_API_KEY:-}"
fi
if [[ -z "$anthropic_key" ]]; then
  echo -e "${RED}No ANTHROPIC_API_KEY found in credentials or environment${NC}" >&2
  exit 1
fi

# Read parent notification config from metadata
parent_telegram_token=$(jq -r '.parent_telegram_token // empty' "$INSTANCE_META" 2>/dev/null)
parent_chat_id=$(jq -r '.parent_chat_id // empty' "$INSTANCE_META" 2>/dev/null)
parent_email=$(jq -r '.parent_email // empty' "$INSTANCE_META" 2>/dev/null)

# ── Step 3: Load fix prompt template ────────────────────────────────────────

template_file="$PROJECT_ROOT/templates/fix-prompt.md"
if [[ ! -f "$template_file" ]]; then
  echo -e "${RED}Template not found: $template_file${NC}" >&2
  exit 1
fi

# ── Step 4: Build Solvr fix section ─────────────────────────────────────────

solvr_fix_file=$(mktemp /tmp/claw-solvr-fix-XXXXXX.txt)
if [[ -n "$solvr_key" && "$solvr_key" != "null" ]]; then
  cat > "$solvr_fix_file" << SOLVREOF
Search Solvr for existing solutions:
\`\`\`bash
curl -s -H "Authorization: Bearer ${solvr_key}" -G --data-urlencode "q=<error description>" "https://api.solvr.dev/v1/problems/search"
\`\`\`

If a matching approach exists, apply its method. After applying, update the approach status:
\`\`\`bash
# Mark as "worked" or "failed"
curl -s -X PATCH "https://api.solvr.dev/v1/approaches/<approach_id>" -H "Authorization: Bearer ${solvr_key}" -H "Content-Type: application/json" -d '{"status": "worked"}'
\`\`\`

If NO match found, post a new problem:
\`\`\`bash
curl -s -X POST "https://api.solvr.dev/v1/problems" -H "Authorization: Bearer ${solvr_key}" -H "Content-Type: application/json" -d '{"title": "<short title>", "description": "<error details>", "tags": ["openclaw", "gateway", "auto-fix"]}'
\`\`\`

After attempting a fix, add an approach to the problem:
\`\`\`bash
curl -s -X POST "https://api.solvr.dev/v1/problems/<problem_id>/approaches" -H "Authorization: Bearer ${solvr_key}" -H "Content-Type: application/json" -d '{"angle": "<what you tried>", "method": "<exact commands>", "status": "worked|failed"}'
\`\`\`
SOLVREOF
else
  echo "No Solvr API key available. Skip all Solvr operations. Set solvr_problem_id and solvr_approach_id to null in output." > "$solvr_fix_file"
fi

# ── Step 5: Build escalation section ────────────────────────────────────────

escalation_file=$(mktemp /tmp/claw-escalation-XXXXXX.txt)
if [[ -n "$parent_telegram_token" && -n "$parent_chat_id" ]]; then
  cat > "$escalation_file" << ESCEOF
Send Telegram notification to parent:
\`\`\`bash
curl -s -X POST "https://api.telegram.org/bot${parent_telegram_token}/sendMessage" -H "Content-Type: application/json" -d "{\"chat_id\": \"${parent_chat_id}\", \"text\": \"ALERT: Instance ${INSTANCE_NAME} has issues that could not be auto-fixed after 3 attempts.\n\nErrors:\n<list each escalated error>\n\nApproaches tried:\n<list each failed approach>\n\nPlease investigate manually: claw ssh ${INSTANCE_NAME}\", \"parse_mode\": \"HTML\"}"
\`\`\`
ESCEOF
else
  echo "No parent Telegram credentials configured. Set telegram_sent to false in escalation output." > "$escalation_file"
fi

if [[ -n "$parent_email" ]]; then
  cat >> "$escalation_file" << EMAILEOF

Send email notification (if mail command available):
\`\`\`bash
echo "ALERT: Instance ${INSTANCE_NAME} has issues that could not be auto-fixed. Please investigate: claw ssh ${INSTANCE_NAME}" | mail -s "OpenClaw Alert: ${INSTANCE_NAME} needs attention" "${parent_email}" 2>/dev/null || true
\`\`\`
EMAILEOF
else
  echo "No parent email configured. Set email_sent to false in escalation output." >> "$escalation_file"
fi

# ── Step 6: Build final prompt ──────────────────────────────────────────────

prompt_tmp=$(mktemp /tmp/claw-fix-XXXXXX.md)
diagnose_file=$(mktemp /tmp/claw-diagnose-out-XXXXXX.json)
trap "rm -f '$prompt_tmp' '$solvr_fix_file' '$escalation_file' '$diagnose_file'" RETURN

echo "$diagnose_output" > "$diagnose_file"

awk -v name="$INSTANCE_NAME" \
    -v diagnose_f="$diagnose_file" \
    -v solvr_f="$solvr_fix_file" \
    -v esc_f="$escalation_file" '
  { gsub(/\{\{INSTANCE_NAME\}\}/, name) }
  /\{\{DIAGNOSE_OUTPUT\}\}/ { while ((getline line < diagnose_f) > 0) print line; next }
  /\{\{SOLVR_FIX_SECTION\}\}/ { while ((getline line < solvr_f) > 0) print line; next }
  /\{\{ESCALATION_SECTION\}\}/ { while ((getline line < esc_f) > 0) print line; next }
  { print }
' "$template_file" > "$prompt_tmp"
rm -f "$diagnose_file" "$solvr_fix_file" "$escalation_file"

# ── Step 7: Upload and run Claude Code ──────────────────────────────────────

remote_prompt="/tmp/claw-fix-prompt.md"
scp -i "$INSTANCE_SSH_KEY" $SSH_OPTS \
  "$prompt_tmp" "${INSTANCE_SSH_USER}@${INSTANCE_IP}:${remote_prompt}" 2>/dev/null

echo -e "${BLUE}Step 2: Running Claude Code fix session on $INSTANCE_NAME...${NC}" >&2

result=$($local_ssh -t "${INSTANCE_SSH_USER}@$INSTANCE_IP" \
  "ANTHROPIC_API_KEY='${anthropic_key}' claude --print \"\$(cat ${remote_prompt})\" ; rm -f ${remote_prompt}" 2>/dev/null)

# Strip TTY control characters
result=$(echo "$result" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')

# Extract JSON from output
json_output=$(echo "$result" | extract_json)

# ── Step 8: Process result ──────────────────────────────────────────────────

if [[ -n "$json_output" ]] && echo "$json_output" | jq . >/dev/null 2>&1; then
  fixed_count=$(echo "$json_output" | jq '.fixed // 0')
  escalated_count=$(echo "$json_output" | jq '.escalated // 0')

  # Send calm summary to parent on success (all fixed, no escalations)
  if [[ "$escalated_count" -eq 0 && "$fixed_count" -gt 0 && -n "$parent_telegram_token" && -n "$parent_chat_id" ]]; then
    summary_msg="Instance ${INSTANCE_NAME}: auto-fixed ${fixed_count} issue(s). All checks passing now."
    curl -s -X POST "https://api.telegram.org/bot${parent_telegram_token}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg chat_id "$parent_chat_id" --arg text "$summary_msg" '{chat_id: $chat_id, text: $text}')" \
      >/dev/null 2>&1 || true
    echo -e "${GREEN}Sent fix summary to parent Telegram${NC}" >&2
  fi

  if [[ "$escalated_count" -gt 0 ]]; then
    echo -e "${RED}$escalated_count issue(s) could not be auto-fixed and were escalated${NC}" >&2
  fi
  if [[ "$fixed_count" -gt 0 ]]; then
    echo -e "${GREEN}$fixed_count issue(s) successfully fixed${NC}" >&2
  fi

  echo "$json_output" | jq .
else
  echo -e "${YELLOW}Warning: Could not parse JSON from Claude Code fix output${NC}" >&2
  jq -n \
    --arg instance "$INSTANCE_NAME" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg raw_output "$result" \
    '{
      instance: $instance,
      timestamp: $timestamp,
      total_errors: 0,
      fixed: 0,
      failed: 0,
      escalated: 0,
      fixes: [],
      escalations: [],
      raw_output: $raw_output
    }'
fi
