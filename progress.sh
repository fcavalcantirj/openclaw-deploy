#!/bin/bash
prd_file="specs/prd-v1.json"
if [ ! -f "$prd_file" ]; then
  echo "0/0 (0%) - PRD not found"
  exit 0
fi
total=$(grep -c '"passes"' "$prd_file" | tr -d '\n')
passed=$(grep -c '"passes": true' "$prd_file" | tr -d '\n')
total=${total:-0}
passed=${passed:-0}
if [ "$total" -eq 0 ]; then
  echo "0/0 (0%)"
else
  percent=$((passed * 100 / total))
  echo "${passed}/${total} (${percent}%)"
fi
