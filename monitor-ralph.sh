#!/bin/bash
# Monitor ralph sessions and start next layer when phase 1 completes
# 
# FIX (2026-02-18): Added grace period after detecting PHASE_1_COMPLETE
# to let ralph-continuous.sh finish its notification cycle before killing.
# Root cause: Monitor was killing sessions immediately upon detection,
# preventing ralph from sending its "Batch Complete" and "PHASE 1 COMPLETE" 
# Telegram notifications.

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID='152099202'
GRACE_PERIOD=90  # seconds to wait for ralph to send notifications

send_telegram() {
  local result
  result=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=$1" \
    -d "parse_mode=Markdown")
  
  # Log if send failed
  if ! echo "$result" | grep -q '"ok":true'; then
    echo "⚠️  Telegram send may have failed: $result" >&2
  fi
}

# Wait for phase completion with grace period for notifications
wait_for_phase_complete() {
  local session_name="$1"
  local log_file="$2"
  local project_name="$3"
  
  echo "📊 Waiting for ${project_name} Phase 1 to complete..."
  
  while true; do
    # Check if session already ended naturally
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
      echo "✅ ${session_name} session ended naturally"
      return 0
    fi
    
    # Check for phase completion in log
    if grep -q "PHASE_1_COMPLETE\|PHASE 1 COMPLETE" "$log_file" 2>/dev/null; then
      echo "✅ ${project_name} Phase 1 COMPLETE detected in log!"
      echo "⏳ Grace period: waiting ${GRACE_PERIOD}s for ralph to send notifications..."
      
      # Grace period - let ralph finish its batch and send notifications
      local waited=0
      while [ $waited -lt $GRACE_PERIOD ]; do
        sleep 10
        waited=$((waited + 10))
        
        # Check if session ended naturally during grace period
        if ! tmux has-session -t "$session_name" 2>/dev/null; then
          echo "✅ ${session_name} exited gracefully during grace period"
          return 0
        fi
        
        echo "   ⏳ ${waited}/${GRACE_PERIOD}s..."
      done
      
      # Grace period over, kill if still running
      if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "⏹️  Grace period over, stopping ${session_name}..."
        tmux kill-session -t "$session_name" 2>/dev/null
      fi
      
      return 0
    fi
    
    sleep 60
  done
}

echo "🔍 Monitoring ralph sessions..."
echo "   Solvr → proactive-amcp → amcp-protocol"
echo "   Grace period: ${GRACE_PERIOD}s after detection"
echo ""

# PHASE 1: Monitor SOLVR
wait_for_phase_complete "ralph-solvr" "/tmp/ralph-solvr.log" "SOLVR"

send_telegram "✅ *SOLVR Phase 1 Complete!*

Starting proactive-amcp next..."

# PHASE 2: Start PROACTIVE-AMCP
echo ""
echo "🚀 Starting PROACTIVE-AMCP..."
cd ~/development/proactive-amcp
tmux new-session -d -s ralph-proactive \
  "BATCH_SIZE=1 BATCH_PAUSE_MINS=25 WAIT_TIME_MINS=60 TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" ./ralph-continuous.sh 2>&1 | tee /tmp/ralph-proactive.log; echo 'PROACTIVE DONE'; sleep 3600"

wait_for_phase_complete "ralph-proactive" "/tmp/ralph-proactive.log" "PROACTIVE-AMCP"

send_telegram "✅ *proactive-amcp Phase 1 Complete!*

Starting amcp-protocol next..."

# PHASE 3: Start AMCP-PROTOCOL
echo ""
echo "🚀 Starting AMCP-PROTOCOL..."
cd ~/development/amcp-protocol
tmux new-session -d -s ralph-amcp \
  "BATCH_SIZE=2 BATCH_PAUSE_MINS=20 WAIT_TIME_MINS=60 TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" ./ralph-continuous.sh 2>&1 | tee /tmp/ralph-amcp.log; echo 'AMCP DONE'; sleep 3600"

wait_for_phase_complete "ralph-amcp" "/tmp/ralph-amcp.log" "AMCP-PROTOCOL"

send_telegram "🎉 *ALL 3 LAYERS Phase 1 COMPLETE!* 🎉

✅ Solvr
✅ proactive-amcp  
✅ amcp-protocol

Ready for Phase 2 when you are, captain! 🏴‍☠️"

echo ""
echo "🎉 ALL 3 LAYERS PHASE 1 COMPLETE!"
echo "📊 Monitor finished at $(date)"
