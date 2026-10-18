"""Offline tests: never read credentials or contact a provider."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "preflight", Path(__file__).resolve().parents[1] / "scripts/openrouter_ci_preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.env = {"OPENROUTER_API_KEY": "fake", "OPENROUTER_TEST_MODEL": "vendor/model",
                    "OPENROUTER_TEST_BUDGET_USD": "1.0"}
        self.data = dict(limit=2.0, limit_remaining=0.5, limit_reset=None,
                         include_byok_in_limit=True)
        self.calls = 0

    def fetch(self, key):
        self.assertEqual(key, "fake")
        self.calls += 1
        return {"data": self.data}

    def test_admits_verified_cap(self):
        self.assertEqual(preflight.admit(self.env, self.fetch), 0.5)
        self.assertEqual(self.calls, 1)

    def test_rejects_missing_credentials_model_or_budget_before_network(self):
        for name, values in {
            "OPENROUTER_API_KEY": ["", " "],
            "OPENROUTER_TEST_MODEL": ["", "openrouter/free", "vendor/model:free"],
            "OPENROUTER_TEST_BUDGET_USD": ["", "bogus", "0", "-1", "nan", "inf"]
        }.items():
            for value in values:
                with self.subTest(name=name, value=value):
                    with self.assertRaises(preflight.AdmissionError):
                        preflight.admit(dict(self.env, **{name: value}), self.fetch)
        self.assertEqual(self.calls, 0)

    def test_rejects_unverified_provider_caps(self):
        original = self.data.copy()
        for name, values in {
            "limit": [None, 0, -1, True, "1", float("inf"), 0.1],
            "limit_remaining": [None, 0, -1, True, "1", float("nan"), 1.5],
            "limit_reset": ["daily", "monthly", ""],
            "include_byok_in_limit": [False, None, 1]
        }.items():
            for value in values:
                with self.subTest(name=name, value=value):
                    self.data = dict(original, **{name: value})
                    with self.assertRaises(preflight.AdmissionError):
                        preflight.admit(self.env, self.fetch)
        for name in original:
            self.data = original.copy()
            del self.data[name]
            with self.assertRaises(preflight.AdmissionError):
                preflight.admit(self.env, self.fetch)

    def test_network_error_is_closed_and_redacted(self):
        def failed(_):
            raise RuntimeError("fake-secret")
        with self.assertRaises(preflight.AdmissionError) as caught:
            preflight.admit(self.env, failed)
        self.assertNotIn("fake-secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
