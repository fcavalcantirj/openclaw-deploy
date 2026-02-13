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
NC='\033[0m' # No Color

CONTEXT_WARNING_THRESHOLD=120000

# Format seconds to hh:mm:ss
format_time() {
    local secs=$1
    printf "%02d:%02d:%02d" $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

# Print exceeded iterations summary
print_exceeded_summary() {
    if [ ${#exceeded_iters[@]} -gt 0 ]; then
        echo ""
        echo -e "${RED}${BOLD}───────────────────────────────────────────────────────────${NC}"
        echo -e "${RED}${BOLD}  ⚠️  ${#exceeded_iters[@]} iteration(s) exceeded ${CONTEXT_WARNING_THRESHOLD} tokens:${NC}"
        for idx in "${!exceeded_iters[@]}"; do
            echo -e "${RED}    • Iteration ${exceeded_iters[$idx]}: ${exceeded_tokens[$idx]} tokens${NC}"
        done
        echo -e "${RED}${BOLD}───────────────────────────────────────────────────────────${NC}"
    fi
}

if [ -z "$1" ]; then
    echo "Usage: $0 <iterations>"
    exit 1
fi

# Show existing claude processes (informational only)
echo -e "${DIM}Claude processes running:${NC}"
ps aux | grep -i claude | grep -v grep | awk '{print "  PID:", $2}' || echo "  None"
echo ""

tmpfile=$(mktemp)

# Cleanup temp file on exit
cleanup() {
    rm -f "$tmpfile"
}
trap cleanup EXIT

overall_start=$(date +%s)
total_iteration_time=0
completed_iterations=0
total_cost=0
total_input_tokens=0
total_output_tokens=0

# Track exceeded iterations
declare -a exceeded_iters=()
declare -a exceeded_tokens=()

# Stuck detection
last_feature=""
stuck_count=0
MAX_STUCK=${MAX_STUCK:-3}

for ((i=1; i<=$1; i++)); do
    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  Iteration $i of $1${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    iter_start=$(date +%s)

    # Run claude synchronously
    claude --dangerously-skip-permissions --no-session-persistence -p --output-format json \
        "@CLAUDE.md @specs/prd-v1.json @specs/progress.txt \
        1. Read CLAUDE.md for project guidelines (GOLDEN RULE: no file over 800 lines). \
        2. Find the highest-priority feature to work on and work only on that feature. \
        3. Check that the types check via pnpm typecheck and that the tests pass via pnpm test. \
        4. Update progress.txt with what you did. \
        5. Update @specs/prd-v1.json with passes = TRUE for the feature you completed. \
        6. Commit your changes. \
        7. Push your changes to the repository. \
        ONLY DO ONE TASK AT A TIME. Ensure no file exceeds 800 lines - split if needed." > "$tmpfile" 2>&1 || true

    iter_end=$(date +%s)
    iter_time=$((iter_end - iter_start))
    total_iteration_time=$((total_iteration_time + iter_time))
    completed_iterations=$((completed_iterations + 1))

    # Parse JSON output (initialize defaults first)
    result_text=""
    cost=0
    input_tokens=0
    cache_read=0
    cache_create=0
    output_tokens=0
    iter_context=0

    if jq -e . "$tmpfile" > /dev/null 2>&1; then
        result_text=$(jq -r '.result // "No result"' "$tmpfile")
        cost=$(jq -r '.total_cost_usd // 0' "$tmpfile")
        input_tokens=$(jq -r '.usage.input_tokens // 0' "$tmpfile")
        cache_read=$(jq -r '.usage.cache_read_input_tokens // 0' "$tmpfile")
        cache_create=$(jq -r '.usage.cache_creation_input_tokens // 0' "$tmpfile")
        output_tokens=$(jq -r '.usage.output_tokens // 0' "$tmpfile")

        # Calculate context for this iteration
        iter_context=$((input_tokens + cache_read + cache_create))

        # Track if exceeded threshold
        if [ "$iter_context" -gt "$CONTEXT_WARNING_THRESHOLD" ]; then
            exceeded_iters+=("$i")
            exceeded_tokens+=("$iter_context")
        fi

        # Accumulate totals (using awk for float addition)
        total_cost=$(echo "$total_cost $cost" | awk '{printf "%.4f", $1 + $2}')
        total_input_tokens=$((total_input_tokens + iter_context))
        total_output_tokens=$((total_output_tokens + output_tokens))

        echo "$result_text"
        echo ""
        echo -e "${BLUE}───────────────────────────────────────────────────────────${NC}"
        echo -e "${BLUE}  🔢 CONTEXT: ${BOLD}${iter_context}${NC}${BLUE} tokens (in=${input_tokens} cache_read=${cache_read} cache_create=${cache_create})${NC}"
        echo -e "${BLUE}  📤 OUTPUT:  ${BOLD}${output_tokens}${NC}${BLUE} tokens${NC}"
        echo -e "${BLUE}  💰 COST:    ${BOLD}\$${cost}${NC}"
        echo -e "${BLUE}───────────────────────────────────────────────────────────${NC}"

        # WARNING if context exceeds threshold
        if [ "$iter_context" -gt "$CONTEXT_WARNING_THRESHOLD" ]; then
            echo ""
            echo -e "${RED}${BOLD}🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨${NC}"
            echo -e "${RED}${BOLD}  ⚠️  WARNING: CONTEXT EXCEEDED ${CONTEXT_WARNING_THRESHOLD} TOKENS!${NC}"
            echo -e "${RED}${BOLD}  ⚠️  This iteration used ${iter_context} tokens${NC}"
            echo -e "${RED}${BOLD}🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨🚨${NC}"
            echo ""
        fi
    else
        echo -e "${YELLOW}Warning: Could not parse JSON output${NC}"
        cat "$tmpfile"
    fi

    echo ""
    echo -e "${YELLOW}⏱  Iteration $i took ${BOLD}$(format_time $iter_time)${NC}"
    echo -e "${GREEN}📊 $(./progress.sh)${NC}"

    # Stuck detection: if same feature fails 3+ iterations, skip it
    if [ -f specs/prd-v1.json ]; then
        current_feature=$(jq -r '[.[] | select(.passes==false)][0].description // "none"' specs/prd-v1.json 2>/dev/null)
        if [ "$current_feature" = "$last_feature" ] && [ "$current_feature" != "none" ]; then
            stuck_count=$((stuck_count + 1))
        else
            stuck_count=0
        fi
        last_feature="$current_feature"

        if [ $stuck_count -ge $MAX_STUCK ]; then
            echo ""
            echo -e "${RED}${BOLD}🔄 STUCK: '$current_feature' failed $stuck_count iterations in a row${NC}"
            jq '([.[] | select(.passes==false)][0]) |= . + {"skipped": true, "passes": "SKIPPED"}' \
                specs/prd-v1.json > specs/prd-v1.json.tmp && \
                mv specs/prd-v1.json.tmp specs/prd-v1.json
            echo -e "${YELLOW}⏭️  Skipped feature, moving on${NC}"
            stuck_count=0
            last_feature=""
        fi
    fi

    if grep -q "<promise>COMPLETE</promise>" "$tmpfile"; then
        overall_end=$(date +%s)
        overall_time=$((overall_end - overall_start))
        avg_time=$((total_iteration_time / completed_iterations))

        echo ""
        echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}${BOLD}  🎉 PRD COMPLETE after $i iterations!${NC}"
        echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${MAGENTA}  ⏱  Overall time:          ${BOLD}$(format_time $overall_time)${NC}"
        echo -e "${MAGENTA}  ⏱  Average per iteration:  ${BOLD}$(format_time $avg_time)${NC}"
        echo -e "${BLUE}  🔢 Total context:          ${BOLD}${total_input_tokens}${NC}${BLUE} tokens${NC}"
        echo -e "${BLUE}  📤 Total output:           ${BOLD}${total_output_tokens}${NC}${BLUE} tokens${NC}"
        echo -e "${BLUE}  💰 Total cost:             ${BOLD}\$${total_cost}${NC}"
        echo -e "${GREEN}  📊 $(./progress.sh)${NC}"
        print_exceeded_summary
        exit 0
    fi
done

overall_end=$(date +%s)
overall_time=$((overall_end - overall_start))
avg_time=$((total_iteration_time / completed_iterations))

echo ""
echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}${BOLD}  Completed $1 iterations${NC}"
echo -e "${MAGENTA}${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}  ⏱  Overall time:          ${BOLD}$(format_time $overall_time)${NC}"
echo -e "${MAGENTA}  ⏱  Average per iteration:  ${BOLD}$(format_time $avg_time)${NC}"
echo -e "${BLUE}  🔢 Total context:          ${BOLD}${total_input_tokens}${NC}${BLUE} tokens${NC}"
echo -e "${BLUE}  📤 Total output:           ${BOLD}${total_output_tokens}${NC}${BLUE} tokens${NC}"
echo -e "${BLUE}  💰 Total cost:             ${BOLD}\$${total_cost}${NC}"
echo -e "${GREEN}  📊 $(./progress.sh)${NC}"
print_exceeded_summary
