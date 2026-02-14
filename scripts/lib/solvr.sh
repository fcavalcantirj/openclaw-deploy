#!/usr/bin/env bash
# =============================================================================
# solvr.sh — Solvr API helper functions for openclaw-deploy
# =============================================================================
# Source this from any script:
#   source "$SCRIPT_DIR/lib/solvr.sh"
#
# Requires:
#   SOLVR_API_KEY — Bearer token for Solvr API (child or parent key)
#   SOLVR_API_URL — (optional) defaults to https://api.solvr.dev/v1
# =============================================================================

SOLVR_API_URL="${SOLVR_API_URL:-https://api.solvr.dev/v1}"
SOLVR_TIMEOUT="${SOLVR_TIMEOUT:-15}"

# ── Internal helpers ─────────────────────────────────────────────────────────

# Verify SOLVR_API_KEY is set; return 1 if not
_solvr_require_key() {
  if [[ -z "${SOLVR_API_KEY:-}" ]]; then
    echo '{"error": "SOLVR_API_KEY not set"}' >&2
    return 1
  fi
}

# Generic Solvr API call
# Usage: _solvr_call METHOD /endpoint [json_body]
# Prints response body to stdout; returns curl exit code
_solvr_call() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"

  _solvr_require_key || return 1

  local url="${SOLVR_API_URL}${endpoint}"
  local curl_args=(
    -s
    --connect-timeout 10
    --max-time "$SOLVR_TIMEOUT"
    -X "$method"
    -H "Authorization: Bearer ${SOLVR_API_KEY}"
    -H "Accept: application/json"
  )

  if [[ -n "$body" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi

  curl "${curl_args[@]}" "$url" 2>/dev/null || echo '{"error": "curl_failed"}'
}

# ── Public API functions ─────────────────────────────────────────────────────

# Search Solvr for problems matching a query
# Usage: solvr_search "openclaw gateway not responding"
# Prints: JSON response from Solvr search API
# Returns: 0 on success (even if no matches), 1 on API/key error
solvr_search() {
  local query="$1"

  if [[ -z "$query" ]]; then
    echo '{"error": "search query is empty"}'
    return 1
  fi

  # URL-encode the query
  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$query'))" 2>/dev/null \
    || echo "$query")

  local response
  response=$(_solvr_call GET "/problems/search?q=${encoded_query}")

  echo "$response"

  # Check if response indicates an error
  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Post a new problem to Solvr
# Usage: solvr_post_problem "Gateway crashes on restart" "Full description here" "openclaw,gateway,crash"
# Prints: JSON response (includes new problem_id in .data.id)
# Returns: 0 on success, 1 on error
solvr_post_problem() {
  local title="$1"
  local description="$2"
  local tags_csv="${3:-openclaw}"

  if [[ -z "$title" ]]; then
    echo '{"error": "problem title is empty"}'
    return 1
  fi

  # Convert comma-separated tags to JSON array
  local tags_json
  tags_json=$(echo "$tags_csv" | tr ',' '\n' | jq -R . | jq -s .)

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg desc "${description:-$title}" \
    --argjson tags "$tags_json" \
    '{title: $title, description: $desc, tags: $tags}')

  local response
  response=$(_solvr_call POST "/problems" "$payload")

  echo "$response"

  # Check for error
  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Add an approach to an existing Solvr problem
# Usage: solvr_add_approach "problem_id" "restart gateway" "sudo systemctl restart openclaw-gateway"
# Prints: JSON response (includes new approach_id in .data.id)
# Returns: 0 on success, 1 on error
solvr_add_approach() {
  local problem_id="$1"
  local angle="$2"
  local method="$3"

  if [[ -z "$problem_id" || -z "$angle" ]]; then
    echo '{"error": "problem_id and angle are required"}'
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg angle "$angle" \
    --arg method "${method:-$angle}" \
    '{angle: $angle, method: $method}')

  local response
  response=$(_solvr_call POST "/problems/${problem_id}/approaches" "$payload")

  echo "$response"

  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Update an approach's status (tried, worked, failed)
# Usage: solvr_update_approach "approach_id" "worked"
# Status values: tried, worked, failed
# Prints: JSON response
# Returns: 0 on success, 1 on error
solvr_update_approach() {
  local approach_id="$1"
  local status="$2"

  if [[ -z "$approach_id" || -z "$status" ]]; then
    echo '{"error": "approach_id and status are required"}'
    return 1
  fi

  # Validate status
  case "$status" in
    tried|worked|failed) ;;
    *)
      echo '{"error": "status must be tried, worked, or failed"}'
      return 1
      ;;
  esac

  local payload
  payload=$(jq -n --arg status "$status" '{status: $status}')

  local response
  response=$(_solvr_call PATCH "/approaches/${approach_id}" "$payload")

  echo "$response"

  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Verify an approach (mark it as verified/confirmed)
# Usage: solvr_verify_approach "approach_id"
# Prints: JSON response
# Returns: 0 on success, 1 on error
solvr_verify_approach() {
  local approach_id="$1"

  if [[ -z "$approach_id" ]]; then
    echo '{"error": "approach_id is required"}'
    return 1
  fi

  local payload
  payload=$(jq -n '{verified: true}')

  local response
  response=$(_solvr_call PATCH "/approaches/${approach_id}" "$payload")

  echo "$response"

  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Get details of a specific problem
# Usage: solvr_get_problem "problem_id"
# Prints: JSON response with problem details and approaches
# Returns: 0 on success, 1 on error
solvr_get_problem() {
  local problem_id="$1"

  if [[ -z "$problem_id" ]]; then
    echo '{"error": "problem_id is required"}'
    return 1
  fi

  local response
  response=$(_solvr_call GET "/problems/${problem_id}")

  echo "$response"

  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}

# Get identity info for current API key
# Usage: solvr_whoami
# Prints: JSON response with agent info
# Returns: 0 on success, 1 on error
solvr_whoami() {
  local response
  response=$(_solvr_call GET "/me")

  echo "$response"

  local err
  err=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
  [[ -z "$err" ]]
}
