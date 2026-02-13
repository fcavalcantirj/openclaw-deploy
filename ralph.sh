#!/bin/bash
set -e

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CONTEXT_WARNING_THRESHOLD=120000

format_time() {
    local secs=$1
    printf "%02d:%02d:%02d" $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

if [ -z "$1" ]; then
    echo "Usage: $0 <iterations>"
    exit 1
fi

echo -e "${DIM}Claude processes running:${NC}"
ps aux | grep -i claude | grep -v grep | awk '{print "  PID:", $2}' || echo "  None"
echo ""

tmpfile=$(mktemp)
trap "rm -f $tmpfile" EXIT

overall_start=$(date +%s)
total_iteration_time=0
completed_iterations=0
total_cost=0
total_input_tokens=0
total_output_tokens=0

for i in $(seq 1 $1); do
  echo ""
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}${BOLD}  Iteration $i of $1${NC}"
  echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"

  iter_start=$(date +%s)

  # Run claude with project context
  claude --dangerously-skip-permissions --no-session-persistence -p --output-format json "@CLAUDE.md @SPEC.md @specs/prd-v1.json @specs/progress.txt \

=== GOLDEN RULES ===
• Real implementation only - no placeholders or stubs
• Test each step before marking passes=true
• Security first - loopback bind, UFW, no credential commits
• One task at a time - complete fully before moving on

=== WORKFLOW ===
1. Read CLAUDE.md for project guidelines
2. Read SPEC.md for full specification details
3. Find next requirement in specs/prd-v1.json where passes=false
4. Implement the requirement (write scripts, configs, prompts)
5. TEST IT - run actual commands to verify it works
6. Update specs/progress.txt with what you did
7. Update specs/prd-v1.json with passes=true
8. COMMIT: git add . && git commit -m 'message'
9. PUSH: git push

=== COMPLETION ===
When ALL requirements pass, output: <promise>COMPLETE</promise>

Work on ONE TASK only. Verify it works. Mark done. Commit." > "$tmpfile" 2>&1 || true

  iter_end=$(date +%s)
  iter_time=$((iter_end - iter_start))
  total_iteration_time=$((total_iteration_time + iter_time))
  completed_iterations=$((completed_iterations + 1))

  if jq -e . "$tmpfile" > /dev/null 2>&1; then
    result_text=$(jq -r '.result // "No result"' "$tmpfile")
    cost=$(jq -r '.total_cost_usd // 0' "$tmpfile")
    input_tokens=$(jq -r '.usage.input_tokens // 0' "$tmpfile")
    output_tokens=$(jq -r '.usage.output_tokens // 0' "$tmpfile")

    total_cost=$(echo "$total_cost $cost" | awk '{printf "%.4f", $1 + $2}')
    total_input_tokens=$((total_input_tokens + input_tokens))
    total_output_tokens=$((total_output_tokens + output_tokens))

    echo "$result_text"
    echo ""
    echo -e "${BLUE}───────────────────────────────────────────────────────────${NC}"
    echo -e "${BLUE}  🔢 INPUT:  ${BOLD}${input_tokens}${NC}${BLUE} tokens${NC}"
    echo -e "${BLUE}  📤 OUTPUT: ${BOLD}${output_tokens}${NC}${BLUE} tokens${NC}"
    echo -e "${BLUE}  💰 COST:   ${BOLD}\$${cost}${NC}"
    echo -e "${BLUE}───────────────────────────────────────────────────────────${NC}"
  else
    echo -e "${YELLOW}Warning: Could not parse JSON output${NC}"
    cat "$tmpfile"
  fi

  echo ""
  echo -e "${YELLOW}⏱  Iteration $i took ${BOLD}$(format_time $iter_time)${NC}"
  echo -e "${GREEN}📊 $(./progress.sh)${NC}"

  if grep -q "<promise>COMPLETE</promise>" "$tmpfile"; then
    overall_end=$(date +%s)
    overall_time=$((overall_end - overall_start))

    echo ""
    echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}  🎉 ALL TASKS COMPLETE after $i iterations!${NC}"
    echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  💰 Total cost: ${BOLD}\$${total_cost}${NC}"
    exit 0
  fi
done

echo ""
echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}${BOLD}  Completed $1 iterations${NC}"
echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}📊 $(./progress.sh)${NC}"
echo -e "${BLUE}💰 Total cost: ${BOLD}\$${total_cost}${NC}"
