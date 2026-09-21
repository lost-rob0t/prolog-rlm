# Benchmark lab

This directory exists only on `feat/benchmark-lab`.

## Branch contract

`feat/benchmark-lab` is a permanent experimental integration branch.

- sync direction: `main -> feat/benchmark-lab`
- forbidden direction: `feat/benchmark-lab -> main`
- never open a merge PR from this branch to `main`
- never force-push either branch
- benchmark artifacts are evidence, not release gates
- every reported result must retain exact source/model/config provenance and raw outputs

The branch is intentionally allowed to accumulate benchmark-only adapters that
would not belong in the domain-neutral Prolog-RLM core.

## Comparative subjects

`matrix.json` defines the common comparison surface:

- OpenCode
- Codex CLI
- Claude Code
- Gemini CLI
- Zara
- Prolog-RLM direct
- Prolog-RLM recursive

Missing executables are recorded as `unavailable`; they are never silently
dropped from a run. `ZARA_ROOT` may point at a Zara checkout. For a self-hosted
OpenAI-compatible model used by Prolog-RLM set:

```sh
export BENCH_ENDPOINT=https://llm.starintel.actor/v1/chat/completions
export BENCH_MODEL='<served-model-id>'
export BENCH_CREDENTIAL_ENV=LLM_STARINTEL_API_KEY
```

Omit `BENCH_CREDENTIAL_ENV` for a trusted endpoint that requires no key.

The StarIntel task corpus is immutable benchmark input in `tasks.json`. Each
entry records its source repository, pinned commit and path. Expected-answer
patterns are grader data and are not inserted into the subject prompt.

Quick matrix:

```sh
python3 lab/benchmark/run.py --dry-run
python3 lab/benchmark/run.py   --suite starintel   --subjects all   --repetitions 3
```

Outputs contain a JSONL record per attempt, a summary, raw stdout/stderr,
SHA-256 hashes, timings, status, score, task provenance and the exact
Prolog-RLM commit.

## Code generation

`codegen_evalplus.py` routes HumanEval+/MBPP+ prompts through the same subject
adapters and emits normal EvalPlus JSONL samples:

```sh
python -m pip install --upgrade evalplus

python3 lab/benchmark/codegen_evalplus.py   --dataset humaneval   --subject prolog-rlm   --full   --out /tmp/prolog-rlm-humaneval.jsonl
```

Grade generated code in the official EvalPlus container, not directly in the
host environment:

```sh
docker run --rm   -v /tmp:/app   ganler/evalplus:latest   evalplus.evaluate   --dataset humaneval   --samples /app/prolog-rlm-humaneval.jsonl
```

The deep host runner does both HumanEval+ and MBPP+ by default for every
available subject. `BENCH_CODEGEN_DATASETS` and `BENCH_CODEGEN_SUBJECTS` can
narrow a diagnostic run.

LiveCodeBench and BigCodeBench remain useful server/model reference suites,
but EvalPlus is the branch's cross-agent code-generation score because its
sample schema lets all seven subjects face identical prompts and one grader.

## `llm.starintel.actor`

`llm_starintel.py` is a dependency-free OpenAI-compatible service benchmark.
It records latency distributions, request throughput, token throughput when
the server reports token usage, response size, HTTP failures and per-request
evidence. Deep mode sweeps context size and concurrency:

```sh
export LLM_STARINTEL_MODEL='<served-model-id>'
export LLM_STARINTEL_API_KEY='<key-if-required>'

python3 lab/benchmark/llm_starintel.py --deep   --out /tmp/llm-starintel-deep.json
```

Deep mode currently covers concurrency `1,2,4,8,16`, context payloads
`2K,16K,64K,128K` characters and at least five requests per matrix cell.

## ExploitGym

The official ExploitGym runner currently has first-class agents for Codex,
Claude Code and Gemini CLI. `exploitgym.sh` deliberately uses that upstream
runner rather than pretending Zara or raw Prolog-RLM implement ExploitGym's
shell/tool agent contract.

A prepared isolated ExploitGym checkout, controller, firewall and LLM proxy are
required. The branch script uses the firewall and budgeted proxy path. It never
generates or stores controller secrets.

```sh
export EXPLOITGYM_ROOT=/path/to/exploitgym
# export the controller/proxy secrets from the prepared deployment
bash lab/benchmark/exploitgym.sh /tmp/exploitgym-run
```

The default deep task list is `data/task_ids/v1.txt`; set
`EXPLOITGYM_TASKS_FILE=data/task_ids/sample.txt` for its 20-task smoke subset.

Raw Prolog-RLM is intentionally reported as unsupported for ExploitGym until a
tool-capable downstream agent adapter exists. Its security model denies ambient
shell/network/filesystem authority; assigning it a fake exploit score would be
misleading. Zara likewise needs an explicit task-runner adapter before it can
be compared on the official ExploitGym agent surface.

## One-command deep host campaign

From a checkout of this branch on the benchmark host:

```sh
bash lab/benchmark/host-deep.sh
```

That campaign runs:

1. canonical deterministic Prolog-RLM benchmark;
2. deterministic depth experiment;
3. the StarIntel comparative matrix with repeated randomized ordering;
4. the deep `llm.starintel.actor` service sweep;
5. full HumanEval+ and MBPP+ generation + containerized grading;
6. full ExploitGym v1 for the upstream-supported common agents when the
   isolated ExploitGym deployment is configured.

The script snapshots the worktree before and after and fails if benchmarking
mutates the branch checkout.
