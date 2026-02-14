# OpenClaw Fix Session — Solvr-Guided Self-Healing

You are fixing issues on OpenClaw Gateway instance: **{{INSTANCE_NAME}}**

## Diagnosis Input

The following is the output from a prior `claw diagnose` run:

```json
{{DIAGNOSE_OUTPUT}}
```

## Instructions

For each failed check in the diagnosis output, attempt to fix it using the Solvr workflow below. Track all fix attempts. After 3 consecutive failed attempts on the same issue, escalate to parent.

**Output ONLY valid JSON** — no markdown, no commentary, no explanation. Your entire response must be a single JSON object.

## Fix Workflow

For each error in the `errors` array from the diagnosis:

### Step 1: Search Solvr for existing solutions

{{SOLVR_FIX_SECTION}}

### Step 2: Apply the fix

If Solvr returned a matching approach:
1. Read the approach's `method` field for the fix steps
2. Execute the fix commands on this machine
3. Verify the fix worked by re-running the relevant health check
4. If fix **worked**: update the approach status to "worked"
5. If fix **failed**: update the approach status to "failed", continue to Step 3

If NO Solvr match was found:
1. Post the issue as a new problem to Solvr
2. Attempt a reasonable fix based on the error (see common fixes below)
3. If fix **worked**: add an approach to the problem with status "worked"
4. If fix **failed**: add an approach to the problem with status "failed"

### Step 3: Retry or escalate

- Track attempts per error (max 3)
- If an approach failed, try a different approach (different angle/method)
- After 3 failed attempts on the SAME error: stop and add it to the escalation list

## Common Fixes Reference

Use these as fallback fix strategies when Solvr has no solutions:

| Check | Common Fix |
|-------|-----------|
| gateway_process | `sudo systemctl restart openclaw-gateway` |
| port_18789 | Kill conflicting process: `sudo fuser -k 18789/tcp`, then restart gateway |
| auth_profiles | Regenerate: `su - openclaw -c 'openclaw gateway init --auth-only'` |
| systemd_service | `sudo systemctl daemon-reload && sudo systemctl restart openclaw-gateway` |
| disk_space | Clear old logs: `sudo journalctl --vacuum-size=100M`, remove temp files |
| memory | Restart gateway (releases memory), check for memory leaks in logs |
| recent_logs | Analyze log errors, restart gateway if fatal errors found |

## Escalation

If any error has 3 failed fix attempts, escalate to parent:

{{ESCALATION_SECTION}}

## Output Format

Return ONLY this JSON (no other text):

```json
{
  "instance": "{{INSTANCE_NAME}}",
  "timestamp": "<ISO 8601 UTC>",
  "total_errors": <number from diagnosis>,
  "fixed": <number of errors successfully fixed>,
  "failed": <number of errors that could not be fixed>,
  "escalated": <number of errors escalated to parent>,
  "fixes": [
    {
      "error": "<error description>",
      "check": "<check name>",
      "attempts": <number 1-3>,
      "status": "fixed|failed|escalated",
      "solvr_problem_id": "<id or null>",
      "solvr_approach_id": "<id or null>",
      "method_used": "<description of fix applied>",
      "detail": "<result detail or escalation reason>"
    }
  ],
  "escalations": [
    {
      "error": "<error description>",
      "attempts": 3,
      "approaches_tried": ["<approach 1>", "<approach 2>", "<approach 3>"],
      "telegram_sent": true,
      "email_sent": true
    }
  ]
}
```

Rules:
- `fixed` + `failed` + `escalated` must equal `total_errors`
- Each error in `fixes` must have 1-3 attempts
- `escalations` array lists only errors that hit the 3-attempt limit
- `solvr_problem_id` and `solvr_approach_id` should be filled when Solvr was used
- Do NOT wrap output in markdown code fences — output raw JSON only
