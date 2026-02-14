# OpenClaw Health Check + Solvr Diagnosis

You are diagnosing an OpenClaw Gateway instance: **{{INSTANCE_NAME}}**

## Instructions

Run each health check below. For each check, record pass/fail and any error details.
After all checks, search Solvr for matching solutions to any errors found.

**Output ONLY valid JSON** — no markdown, no commentary, no explanation. Your entire response must be a single JSON object.

## Health Checks

Run these checks in order. For each, set `"status": "pass"` or `"status": "fail"` with an `"error"` message if failed.

### 1. gateway_process
```bash
pgrep -f "openclaw gateway" >/dev/null 2>&1
```

### 2. port_18789
```bash
ss -tlnp | grep -q ':18789'
```

### 3. auth_profiles
```bash
# Verify auth-profiles.json exists and has valid format
AUTH_FILE="$HOME/.openclaw/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_FILE" ]; then
  jq -e '.version and .profiles and .order' "$AUTH_FILE" >/dev/null 2>&1
fi
```

### 4. systemd_service
```bash
sudo systemctl is-active openclaw-gateway
```

### 5. disk_space
```bash
# Fail if less than 20% free
USAGE=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
[ "$USAGE" -lt 80 ]
```

### 6. memory
```bash
# Fail if over 90% used
MEM_PCT=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100}')
[ "$MEM_PCT" -lt 90 ]
```

### 7. recent_logs
```bash
# Check for errors in last 50 gateway log lines
sudo journalctl -u openclaw-gateway -n 50 --no-pager 2>/dev/null
# Fail if "fatal" or "CRASH" found, pass otherwise (warnings are OK)
```

## Solvr Integration

{{SOLVR_SECTION}}

## Output Format

Return ONLY this JSON (no other text):

```json
{
  "instance": "{{INSTANCE_NAME}}",
  "timestamp": "<ISO 8601 UTC>",
  "checks_passed": <number>,
  "checks_failed": <number>,
  "checks": {
    "gateway_process": {"status": "pass|fail", "error": "...or null"},
    "port_18789": {"status": "pass|fail", "error": "...or null"},
    "auth_profiles": {"status": "pass|fail", "error": "...or null"},
    "systemd_service": {"status": "pass|fail", "error": "...or null"},
    "disk_space": {"status": "pass|fail", "detail": "XX% used", "error": "...or null"},
    "memory": {"status": "pass|fail", "detail": "XX% used", "error": "...or null"},
    "recent_logs": {"status": "pass|fail", "error": "...or null", "log_snippet": "last 3 lines"}
  },
  "errors": ["list of error messages for failed checks"],
  "solvr_matches": [
    {"error": "...", "problem_id": "...", "title": "...", "approach": "..."}
  ],
  "solvr_posts": [
    {"error": "...", "problem_id": "...", "title": "..."}
  ]
}
```

Rules:
- `checks_passed` + `checks_failed` must equal 7 (total checks)
- `errors` array contains one string per failed check
- `solvr_matches` contains results from Solvr search (empty array if no Solvr key or no matches)
- `solvr_posts` contains new problems posted to Solvr (empty array if none posted)
- Do NOT wrap output in markdown code fences — output raw JSON only
