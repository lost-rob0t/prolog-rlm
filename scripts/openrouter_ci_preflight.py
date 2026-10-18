#!/usr/bin/env python3
"""Fail-closed CI-only admission for explicitly requested paid integration tests."""
import json
import math
import os
import sys
import urllib.request


class AdmissionError(ValueError):
    pass


def positive_number(value):
    return (type(value) in (int, float) and math.isfinite(value) and value > 0)


def admit(env, fetch):
    key = env.get("OPENROUTER_API_KEY", "").strip()
    model = env.get("OPENROUTER_TEST_MODEL", "").strip()
    if not key:
        raise AdmissionError("OPENROUTER_API_KEY is required")
    if not model or model == "openrouter/free" or model.endswith(":free"):
        raise AdmissionError("OPENROUTER_TEST_MODEL must explicitly name a paid model")
    try:
        budget = float(env.get("OPENROUTER_TEST_BUDGET_USD", ""))
    except ValueError:
        budget = None
    if not positive_number(budget):
        raise AdmissionError("OPENROUTER_TEST_BUDGET_USD must be finite and positive")
    # A configured number alone is not enforcement. Verify the dedicated key's
    # provider-side cap before admitting any generation calls.
    try:
        data = fetch(key)["data"]
        limit = data["limit"]
        remaining = data["limit_remaining"]
        valid = (positive_number(limit) and positive_number(remaining)
                 and remaining <= limit and remaining <= budget
                 and data["limit_reset"] is None
                 and data["include_byok_in_limit"] is True)
    except Exception:
        raise AdmissionError("Could not verify OpenRouter key spending cap") from None
    if not valid:
        raise AdmissionError("Require a capped non-resetting CI key with BYOK included and remaining credits within the configured allowance")
    return remaining


def fetch_key(key):
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/key",
        headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def main():
    try:
        remaining = admit(os.environ, fetch_key)
    except AdmissionError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f"Paid integration admitted: provider key remaining cap USD {remaining:g}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
