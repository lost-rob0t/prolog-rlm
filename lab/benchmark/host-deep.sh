#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BRANCH="$(git -C "$ROOT" branch --show-current)"
if [[ "$BRANCH" != "feat/benchmark-lab" && "${BENCH_ALLOW_OTHER_BRANCH:-0}" != "1" ]]; then
  echo "refusing deep benchmark outside feat/benchmark-lab (current: $BRANCH)" >&2
  exit 2
fi

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${BENCH_OUT:-$ROOT/.bench-results/$STAMP}"
mkdir -p "$OUT"

git -C "$ROOT" rev-parse HEAD > "$OUT/prolog-rlm.sha"
git -C "$ROOT" status --porcelain=v1 > "$OUT/worktree-before.txt"

echo "== deterministic Prolog-RLM baseline =="
swipl -q -s "$ROOT/benchmark/run.pl" -- deterministic   "$OUT/prolog-rlm-deterministic.json"

echo "== deterministic deep recursion experiment =="
swipl -q -s "$ROOT/benchmark/run.pl" -- deep-experiment   "$OUT/prolog-rlm-deep-experiment.json"

echo "== StarIntel comparative task matrix =="
python3 "$ROOT/lab/benchmark/run.py"   --suite starintel   --subjects all   --repetitions "${BENCH_REPETITIONS:-3}"   --timeout "${BENCH_TASK_TIMEOUT:-240}"   --out "$OUT/starintel"

if [[ -n "${LLM_STARINTEL_MODEL:-}" ]]; then
  echo "== llm.starintel.actor deep service run =="
  python3 "$ROOT/lab/benchmark/llm_starintel.py"     --deep     --out "$OUT/llm-starintel-deep.json"
else
  echo "SKIP llm.starintel.actor: set LLM_STARINTEL_MODEL" | tee "$OUT/llm-starintel.SKIP"
fi

if command -v evalplus.evaluate >/dev/null 2>&1; then
  IFS=',' read -r -a DATASETS <<< "${BENCH_CODEGEN_DATASETS:-humaneval,mbpp}"
  IFS=',' read -r -a SUBJECTS <<< "${BENCH_CODEGEN_SUBJECTS:-opencode,codex,claude-code,gemini-cli,zara,prolog-rlm-direct,prolog-rlm}"
  for dataset in "${DATASETS[@]}"; do
    for subject in "${SUBJECTS[@]}"; do
      sample="$OUT/evalplus/${dataset}/${subject}.jsonl"
      mkdir -p "$(dirname "$sample")"
      echo "== EvalPlus generate: $dataset / $subject =="
      set +e
      python3 "$ROOT/lab/benchmark/codegen_evalplus.py"         --dataset "$dataset"         --subject "$subject"         --full         --timeout "${BENCH_CODEGEN_TIMEOUT:-300}"         --out "$sample"
      gen_status=$?
      set -e

      if [[ -s "$sample" ]]; then
        echo "== EvalPlus grade: $dataset / $subject =="
        docker run --rm           -v "$OUT/evalplus:/app"           ganler/evalplus:latest           evalplus.evaluate           --dataset "$dataset"           --samples "/app/${dataset}/${subject}.jsonl"           > "$OUT/evalplus/${dataset}/${subject}.eval.log" 2>&1 || true
      fi
      printf '%s\n' "$gen_status" > "$OUT/evalplus/${dataset}/${subject}.generate-status"
    done
  done
else
  echo "SKIP EvalPlus: evalplus.evaluate not installed" | tee "$OUT/evalplus.SKIP"
fi

if [[ -n "${EXPLOITGYM_ROOT:-}" ]]; then
  "$ROOT/lab/benchmark/exploitgym.sh" "$OUT/exploitgym"
else
  echo "SKIP ExploitGym: set EXPLOITGYM_ROOT to a prepared official checkout"     | tee "$OUT/exploitgym.SKIP"
fi

git -C "$ROOT" status --porcelain=v1 > "$OUT/worktree-after.txt"
if ! cmp -s "$OUT/worktree-before.txt" "$OUT/worktree-after.txt"; then
  echo "benchmark changed the prolog-rlm worktree; inspect $OUT/worktree-after.txt" >&2
  exit 3
fi

echo "benchmark artifacts: $OUT"
