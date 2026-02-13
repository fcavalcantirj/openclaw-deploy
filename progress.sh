#!/bin/bash
# Progress tracker for ralph
SPECS_FILE="specs/prd-v1.json"
if [ -f "$SPECS_FILE" ]; then
    total=$(jq 'length' "$SPECS_FILE")
    passed=$(jq '[.[] | select(.passes==true)] | length' "$SPECS_FILE")
    skipped=$(jq '[.[] | select(.passes=="SKIPPED")] | length' "$SPECS_FILE")
    remaining=$((total - passed - skipped))
    echo "✅ $passed/$total passed | ⏭️ $skipped skipped | 📋 $remaining remaining"
else
    echo "No specs file found"
fi
