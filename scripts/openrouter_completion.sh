#!/usr/bin/env bash
# Fetch completion/generation data from OpenRouter for debugging provider IO.
#
# Usage:
#   scripts/openrouter_completion.sh <generation-id>         # usage & request metadata
#   scripts/openrouter_completion.sh <generation-id> --content  # stored prompt/completion text
#   scripts/openrouter_completion.sh --key                   # current API key info
#   scripts/openrouter_completion.sh --credits               # remaining credits
#
# The API key is resolved from $OPENROUTER_API_KEY, falling back to the
# git-ignored .env at the repository root (loaded by direnv via .envrc).
# The key is never echoed. Generation ids come from model_response.response_id
# (the "gen-..." id) recorded in completion results and traces.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${OPENROUTER_API_KEY:-}" && -f "$repo_root/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$repo_root/.env"; set +a
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "error: OPENROUTER_API_KEY is not set and $repo_root/.env was not found" >&2
  exit 2
fi

base="https://openrouter.ai/api/v1"
path=""
case "${1:-}" in
  --key)     path="/auth/key" ;;
  --credits) path="/credits" ;;
  gen-*|"")  path="/generation?id=${1:-}" ;;
  *) echo "error: unknown argument '${1:-}' (expected <generation-id>, --content after one, --key, or --credits)" >&2; exit 2 ;;
esac

if [[ "${2:-}" == "--content" ]]; then
  path="/generation/content?id=${1:?}"
fi

if [[ -z "${1:-}" && -z "${2:-}" ]]; then
  echo "error: nothing to fetch; pass <generation-id>, --key, or --credits" >&2
  exit 2
fi

curl_args=(
  -sS
  -w '\nhttp_status:%{http_code}\n'
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}"
  "${base}${path}"
)

response="$(curl "${curl_args[@]}")"

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$response" | sed '$d' | jq . || printf '%s\n' "$response"
else
  printf '%s\n' "$response"
fi
