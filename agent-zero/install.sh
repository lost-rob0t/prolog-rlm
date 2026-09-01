#!/usr/bin/env sh
set -eu

A0_USR="${1:-/a0/usr}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

mkdir -p "$A0_USR/agents"

for profile in prolog-rlm-rage-hardening agentprolog-rage-integration; do
  rm -rf "$A0_USR/agents/$profile"
  cp -R "$ROOT/agent-zero/usr/agents/$profile" "$A0_USR/agents/$profile"
done

# Remove the retired Hackmode worker identities so one installation cannot
# accidentally leave both the old and new ownership models active.
rm -rf \
  "$A0_USR/agents/hackmode-rage-database" \
  "$A0_USR/agents/hackmode-rage-hackpert"

printf 'Installed Prolog-RLM feature-freeze Auto-RAGE profiles into %s/agents\n' "$A0_USR"
printf 'Profiles: prolog-rlm-rage-hardening, agentprolog-rage-integration\n'
