#!/usr/bin/env python3
"""OpenAI-compatible throughput/latency benchmark for llm.starintel.actor.

This intentionally uses only Python's standard library so it can run directly
on the inference host without altering the serving environment.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import statistics
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ENDPOINT = "https://llm.starintel.actor/v1/chat/completions"


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * p)))
    return round(ordered[index], 3)


def request_once(
    endpoint: str,
    model: str,
    api_key: str | None,
    prompt: str,
    max_tokens: int,
    timeout: int,
) -> dict[str, Any]:
    payload = json.dumps(
        {
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0,
            "max_tokens": max_tokens,
            "stream": False,
        }
    ).encode()
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = urllib.request.Request(endpoint, data=payload, headers=headers, method="POST")
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
            elapsed = time.perf_counter() - started
            data = json.loads(body)
            usage = data.get("usage") or {}
            completion_tokens = usage.get("completion_tokens")
            return {
                "ok": True,
                "status": response.status,
                "elapsed_ms": round(elapsed * 1000, 3),
                "completion_tokens": completion_tokens,
                "prompt_tokens": usage.get("prompt_tokens"),
                "total_tokens": usage.get("total_tokens"),
                "tokens_per_second": (
                    round(completion_tokens / elapsed, 3)
                    if isinstance(completion_tokens, int) and elapsed > 0
                    else None
                ),
                "response_chars": len(
                    (((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
                ),
                "model": data.get("model"),
            }
    except urllib.error.HTTPError as error:
        return {
            "ok": False,
            "status": error.code,
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
            "error": error.read().decode("utf-8", "replace")[:2000],
        }
    except Exception as error:
        return {
            "ok": False,
            "status": None,
            "elapsed_ms": round((time.perf_counter() - started) * 1000, 3),
            "error": repr(error),
        }


def make_prompt(context_chars: int) -> str:
    block = (
        "StarIntel benchmark payload. Preserve deterministic behavior. "
        "The verification token is STARINTEL_BENCH_OK. "
    )
    repeats = max(1, context_chars // len(block))
    context = (block * repeats)[:context_chars]
    return (
        f"{context}\n\nReturn exactly STARINTEL_BENCH_OK followed by one short sentence "
        "describing that this was a latency benchmark."
    )


def run_level(
    endpoint: str,
    model: str,
    api_key: str | None,
    concurrency: int,
    context_chars: int,
    requests: int,
    max_tokens: int,
    timeout: int,
) -> dict[str, Any]:
    prompt = make_prompt(context_chars)
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [
            pool.submit(
                request_once,
                endpoint,
                model,
                api_key,
                prompt,
                max_tokens,
                timeout,
            )
            for _ in range(requests)
        ]
        rows = [future.result() for future in futures]
    wall = time.perf_counter() - started
    ok = [x for x in rows if x["ok"]]
    latencies = [x["elapsed_ms"] for x in ok]
    token_rates = [
        x["tokens_per_second"]
        for x in ok
        if isinstance(x.get("tokens_per_second"), (int, float))
    ]
    return {
        "concurrency": concurrency,
        "context_chars": context_chars,
        "requests": requests,
        "successes": len(ok),
        "failures": requests - len(ok),
        "wall_ms": round(wall * 1000, 3),
        "requests_per_second": round(len(ok) / wall, 3) if wall > 0 else None,
        "latency_ms": {
            "min": round(min(latencies), 3) if latencies else None,
            "mean": round(statistics.mean(latencies), 3) if latencies else None,
            "p50": percentile(latencies, 0.50),
            "p95": percentile(latencies, 0.95),
            "p99": percentile(latencies, 0.99),
            "max": round(max(latencies), 3) if latencies else None,
        },
        "tokens_per_second": {
            "mean": round(statistics.mean(token_rates), 3) if token_rates else None,
            "p50": percentile(token_rates, 0.50),
            "p95": percentile(token_rates, 0.95),
        },
        "rows": rows,
    }


def parse_ints(value: str) -> list[int]:
    return [int(x.strip()) for x in value.split(",") if x.strip()]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--endpoint",
        default=os.environ.get("LLM_STARINTEL_ENDPOINT", DEFAULT_ENDPOINT),
    )
    parser.add_argument("--model", default=os.environ.get("LLM_STARINTEL_MODEL"))
    parser.add_argument(
        "--api-key-env",
        default=os.environ.get("LLM_STARINTEL_API_KEY_ENV", "LLM_STARINTEL_API_KEY"),
    )
    parser.add_argument("--concurrency", default="1,2,4")
    parser.add_argument("--context-chars", default="2048,16384")
    parser.add_argument("--requests-per-level", type=int, default=3)
    parser.add_argument("--max-tokens", type=int, default=96)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--deep", action="store_true")
    parser.add_argument("--out", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.model:
        raise SystemExit("LLM_STARINTEL_MODEL or --model is required")
    if args.deep:
        concurrencies = [1, 2, 4, 8, 16]
        contexts = [2048, 16384, 65536, 131072]
        requests = max(args.requests_per_level, 5)
    else:
        concurrencies = parse_ints(args.concurrency)
        contexts = parse_ints(args.context_chars)
        requests = args.requests_per_level

    api_key = os.environ.get(args.api_key_env) if args.api_key_env else None
    levels = []
    for context_chars in contexts:
        for concurrency in concurrencies:
            level = run_level(
                args.endpoint,
                args.model,
                api_key,
                concurrency,
                context_chars,
                requests,
                args.max_tokens,
                args.timeout,
            )
            levels.append(level)
            print(
                json.dumps(
                    {
                        "context_chars": context_chars,
                        "concurrency": concurrency,
                        "successes": level["successes"],
                        "failures": level["failures"],
                        "p50_ms": level["latency_ms"]["p50"],
                        "p95_ms": level["latency_ms"]["p95"],
                        "rps": level["requests_per_second"],
                    },
                    sort_keys=True,
                ),
                flush=True,
            )

    report = {
        "schema": "starintel.llm-host-benchmark.v1",
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "endpoint": args.endpoint,
        "model_requested": args.model,
        "deep": args.deep,
        "max_tokens": args.max_tokens,
        "levels": levels,
    }
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding="utf-8")
    print(output)
    return 0 if all(level["failures"] == 0 for level in levels) else 1


if __name__ == "__main__":
    raise SystemExit(main())
