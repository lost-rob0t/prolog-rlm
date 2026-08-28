#!/usr/bin/env bash
# Loop the #288 plan-graph contract gate until every requirement fact is
# defined, or give up after MAX_ATTEMPTS. Usage: scripts/plan_graph_contract_check.sh [max_attempts]
set -u
MAX_ATTEMPTS="${1:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
attempt=1
rc=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "== plan-graph contract check, attempt ${attempt}/${MAX_ATTEMPTS} =="
    if swipl -q -s "${SCRIPT_DIR}/plan_graph_contract_check.pl"; then
        rc=0
        break
    fi
    attempt=$((attempt + 1))
    sleep 2
done
if [ "$rc" -ne 0 ]; then
    echo "plan-graph contract check: FAILING after ${MAX_ATTEMPTS} attempts"
fi
exit "$rc"
