#!/bin/bash
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

BATCH_SIZE=${BATCH_SIZE:-3}
BATCH_PAUSE_MINS=${BATCH_PAUSE_MINS:-1}
WAIT_TIME_MINS=${WAIT_TIME_MINS:-5}
BATCH_PAUSE_SECS=$((BATCH_PAUSE_MINS * 60))
WAIT_TIME_SECS=$((WAIT_TIME_MINS * 60))

# Message via OpenClaw
notify() {
  local msg="$1"
  openclaw message send --channel telegram --target 152099202 --message "$msg" 2>/dev/null || true
}

format_time() {
  local secs=$1
  printf "%02d:%02d:%02d" $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

batch_count=0
runner_start=$(date +%s)

trap 'echo -e "\n${YELLOW}Interrupted.${NC}"; exit 1' INT TERM

echo -e "${MAGENTA}${BOLD}🚀 OpenClaw Deploy - 1 min pause${NC}"
notify "🚀 Ralph started - $(./progress.sh)"

while true; do
  batch_count=$((batch_count + 1))
  batch_start=$(date +%s)

  echo -e "${CYAN}${BOLD}▶ BATCH #${batch_count}${NC}"

  tmplog=$(mktemp)
  ./ralph.sh $BATCH_SIZE 2>&1 | tee "$tmplog"

  prd_complete=false
  grep -q "<promise>COMPLETE</promise>" "$tmplog" 2>/dev/null && prd_complete=true

  rm -f "$tmplog"

  batch_end=$(date +%s)
  batch_time=$((batch_end - batch_start))

  if [ "$prd_complete" = true ]; then
    total_time=$((batch_end - runner_start))
    echo -e "${GREEN}${BOLD}🎉 ALL COMPLETE!${NC}"
    notify "🎉 ALL TASKS COMPLETE! $(./progress.sh) - $(format_time $total_time)"
    exit 0
  fi

  progress=$(./progress.sh)
  echo -e "${GREEN}✅ Batch #${batch_count} done - ${progress}${NC}"
  notify "✅ Batch #${batch_count} done - ${progress} - pausing 1 min"

  sleep $BATCH_PAUSE_SECS
done
