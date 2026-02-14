#!/usr/bin/env bats
# Tests for the claw CLI dispatcher

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLAW="$PROJECT_ROOT/claw"

setup() {
  # We test the real claw file but with no real instances
  true
}

# ── Usage ────────────────────────────────────────────────────────────────────

@test "claw: shows usage with no args" {
  run "$CLAW"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"Commands:"* ]]
}

@test "claw: shows usage with help" {
  run "$CLAW" help
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "claw: unknown command shows error" {
  run "$CLAW" nonexistentcommand
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command"* ]]
}

# ── New commands appear in usage ─────────────────────────────────────────────

@test "claw: usage lists setup-amcp command" {
  run "$CLAW"
  [[ "$output" == *"setup-amcp"* ]]
}

@test "claw: usage lists config command" {
  run "$CLAW"
  [[ "$output" == *"config"* ]]
}

@test "claw: usage lists checkpoint command" {
  run "$CLAW"
  [[ "$output" == *"checkpoint"* ]]
}

@test "claw: usage lists diagnose command" {
  run "$CLAW"
  [[ "$output" == *"diagnose"* ]]
}

@test "claw: usage lists auth command" {
  run "$CLAW"
  [[ "$output" == *"auth"* ]]
}

# ── Line count ───────────────────────────────────────────────────────────────

@test "claw: is under 250 lines (was 554)" {
  local lines
  lines=$(wc -l < "$CLAW")
  [ "$lines" -lt 250 ]
}
