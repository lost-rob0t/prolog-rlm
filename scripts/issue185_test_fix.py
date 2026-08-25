#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
test = root / "test/rlm_reasoning_control_test.pl"
text = test.read_text()
text = text.replace("rlm_reasoning_control:capture_model",
                    "plunit_rlm_reasoning_control:capture_model")
text = text.replace("rlm_reasoning_control:capture_planner",
                    "plunit_rlm_reasoning_control:capture_planner")
test.write_text(text)
Path(__file__).unlink()
