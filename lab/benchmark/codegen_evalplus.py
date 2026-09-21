#!/usr/bin/env python3
"""Generate EvalPlus samples through the comparative subject adapters."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import run as bench


def dataset(name: str, mini: bool) -> dict:
    try:
        from evalplus.data import get_human_eval_plus, get_mbpp_plus
    except ImportError as error:
        raise SystemExit(
            "EvalPlus is required: python -m pip install --upgrade evalplus"
        ) from error
    if name == "humaneval":
        return get_human_eval_plus(mini=mini)
    if name == "mbpp":
        return get_mbpp_plus(mini=mini)
    raise ValueError(name)


def extract_code(text: str) -> str:
    blocks = re.findall(r"```(?:python)?\s*\n(.*?)```", text, re.I | re.S)
    if blocks:
        return max(blocks, key=len).strip() + "\n"
    return text.strip() + "\n"


def task_prompt(problem: dict) -> str:
    prompt = problem["prompt"]
    return (
        "Solve this Python code-generation benchmark. Return only the complete "
        "Python implementation, with no Markdown fences or explanation. Preserve "
        "the requested public function signature.\n\n"
        f"{prompt}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", choices=["humaneval", "mbpp"], default="humaneval")
    parser.add_argument("--subject", required=True)
    parser.add_argument("--matrix", type=Path, default=bench.DEFAULT_MATRIX)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--mini", action="store_true")
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--out", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    matrix = bench.load_json(args.matrix)
    cfg = matrix["subjects"].get(args.subject)
    if cfg is None:
        raise SystemExit(f"unknown subject: {args.subject}")
    subject = bench.Subject(args.subject, cfg["kind"], cfg)
    problems = dataset(args.dataset, args.mini)
    items = list(problems.items())
    if not args.full:
        items = items[: args.limit]

    args.out.parent.mkdir(parents=True, exist_ok=True)
    metadata = args.out.with_suffix(args.out.suffix + ".meta.jsonl")
    failures = 0
    with args.out.open("w", encoding="utf-8") as samples, metadata.open(
        "w", encoding="utf-8"
    ) as meta:
        for index, (task_id, problem) in enumerate(items, 1):
            prompt = task_prompt(problem)
            result = bench.run_subject(subject, prompt, args.timeout)
            output = result.pop("stdout")
            stderr = result.pop("stderr")
            ok = result["status"] == "completed"
            failures += int(not ok)
            sample = {
                "task_id": task_id,
                "solution": extract_code(output) if ok else "",
            }
            samples.write(json.dumps(sample, sort_keys=True) + "\n")
            meta.write(
                json.dumps(
                    {
                        "task_id": task_id,
                        "subject": args.subject,
                        "prompt_sha256": bench.sha256_text(prompt),
                        "stdout_sha256": bench.sha256_text(output),
                        "stderr_sha256": bench.sha256_text(stderr),
                        **result,
                    },
                    sort_keys=True,
                )
                + "\n"
            )
            print(
                json.dumps(
                    {
                        "index": index,
                        "task_id": task_id,
                        "status": result["status"],
                        "elapsed_ms": result["elapsed_ms"],
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
