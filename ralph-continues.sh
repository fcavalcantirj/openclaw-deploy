#!/bin/bash
set -e

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Configuration
BATCH_SIZE=${BATCH_SIZE:-3}
BATCH_PAUSE_MINS=${BATCH_PAUSE_MINS:-2}
WAIT_TIME_MINS=${WAIT_TIME_MINS:-5}
BATCH_PAUSE_SECS=$((BATCH_PAUSE_MINS * 60))
WAIT_TIME_SECS=$((WAIT_TIME_MINS * 60))

# Telegram notifications (set env vars to enable)
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-""}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-"152099202"}

send_telegram() {
  local message="$1"
  if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${message}" \
      -d "parse_mode=Markdown" > /dev/null 2>&1
  fi
}

format_time() {
  local secs=$1
  printf "%02d:%02d:%02d" $((secs/3600)) $((secs%3600/60)) $((secs%60))
}

batch_count=0
total_iterations=0
runner_start=$(date +%s)

trap 'echo -e "\n${YELLOW}Interrupted.${NC}"; exit 1' INT TERM

echo ""
echo -e "${MAGENTA}${BOLD}╔═════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}${BOLD}║  🚀 OpenClaw Deploy - Continuous Runner                     ║${NC}"
echo -e "${MAGENTA}${BOLD}║  📦 Batch: ${BATCH_SIZE} iterations | ⏸️  Pause: ${BATCH_PAUSE_MINS} min              ║${NC}"
echo -e "${MAGENTA}${BOLD}║  🕐 Started: $(date '+%Y-%m-%d %H:%M:%S')                            ║${NC}"
echo -e "${MAGENTA}${BOLD}╚═════════════════════════════════════════════════════════════╝${NC}"
echo ""

send_telegram "🚀 *OpenClaw Deploy* started

📦 Batch: ${BATCH_SIZE} iterations
⏸️ Pause: ${BATCH_PAUSE_MINS} min
📊 $(./progress.sh)"

while true; do
  batch_count=$((batch_count + 1))
  batch_start=$(date +%s)

  echo ""
  echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}${BOLD}│  ▶ BATCH #${batch_count} - Running ${BATCH_SIZE} iterations                       │${NC}"
  echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────────────────┘${NC}"

  send_telegram "▶️ *Batch #${batch_count}* starting

📊 $(./progress.sh)"

  tmplog=$(mktemp)
  ./ralph.sh $BATCH_SIZE 2>&1 | tee "$tmplog"
  exit_code=${PIPESTATUS[0]}

  # Check for completion
  prd_complete=false
  if grep -q "<promise>COMPLETE</promise>" "$tmplog" 2>/dev/null; then
    prd_complete=true
  fi

  # Check for API errors
  api_error=false
  if [ $exit_code -ne 0 ]; then
    if ! grep -q '"is_error":false' "$tmplog"; then
      api_error=true
    fi
  fi

  rm -f "$tmplog"

  batch_end=$(date +%s)
  batch_time=$((batch_end - batch_start))
  total_iterations=$((total_iterations + BATCH_SIZE))

  if [ "$prd_complete" = true ]; then
    runner_end=$(date +%s)
    total_time=$((runner_end - runner_start))

    echo ""
    echo -e "${GREEN}${BOLD}╔═════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  🎉 ALL TASKS COMPLETE!                                     ║${NC}"
    echo -e "${GREEN}${BOLD}║  📦 Batches: ${batch_count} | 🔄 Iterations: ${total_iterations}                       ║${NC}"
    echo -e "${GREEN}${BOLD}║  ⏱️  Total time: $(format_time $total_time)                                   ║${NC}"
    echo -e "${GREEN}${BOLD}║  📊 $(./progress.sh)                                        ║${NC}"
    echo -e "${GREEN}${BOLD}╚═════════════════════════════════════════════════════════════╝${NC}"

    send_telegram "🎉 *ALL TASKS COMPLETE!*

📦 Batches: ${batch_count}
🔄 Iterations: ${total_iterations}
⏱️ Time: $(format_time $total_time)
📊 $(./progress.sh)"

    exit 0
  fi

  if [ "$api_error" = true ]; then
    echo ""
    echo -e "${RED}${BOLD}  🚨 API Error - Waiting ${WAIT_TIME_MINS} minutes...${NC}"
    
    send_telegram "🚨 *API Error* - Batch #${batch_count}

⏸️ Waiting ${WAIT_TIME_MINS} min
📊 $(./progress.sh)"

    sleep $WAIT_TIME_SECS
  else
    echo ""
    echo -e "${GREEN}${BOLD}  ✅ Batch #${batch_count} done ($(format_time $batch_time)) - $(./progress.sh)${NC}"
    echo -e "${YELLOW}  ⏸️  Pausing ${BATCH_PAUSE_MINS} minutes...${NC}"

    send_telegram "✅ *Batch #${batch_count}* complete

⏱️ Duration: $(format_time $batch_time)
📊 $(./progress.sh)
⏸️ Next batch in ${BATCH_PAUSE_MINS} min"

    sleep $BATCH_PAUSE_SECS
  fi
done
