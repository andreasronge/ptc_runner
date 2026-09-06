"""Check the benchmark's CLI outcome assertions without opening private records."""

import contextlib
import io
import json
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class TraceQueryHarnessTest(unittest.TestCase):
    def run_harness(
        self, failure_code="source_limit_exceeded", selected=False, admit=False
    ):
        def process(args, **_kwargs):
            resource = next(arg for arg in args if arg.startswith("traces="))
            size = int(Path(resource.removeprefix("traces=")).parent.name)
            rejected = size == 1025 and not admit
            if rejected:
                records = [{"type": "command-error", "code": failure_code}]
            else:
                runs = 1 if selected else size
                records = [{"type": "session-started"}] + [
                    {
                        "type": "evaluation",
                        "result": {
                            "status": "ok",
                            "value": {
                                "runs": runs,
                                "pages": (runs + 49) // 50,
                                "max_page": min(runs, 50),
                            },
                            "duration_ms": 1,
                            "usage": {"continuation": {}},
                        },
                    }
                ] * 3
            return SimpleNamespace(
                stdout=io.StringIO("\n".join(map(json.dumps, records))),
                wait=lambda: 1 if rejected else 0,
            )

        script = Path(__file__).with_name("dabstep_trace_queries.py")
        argv = [str(script)] + (["--selected-run", "known-run"] if selected else [])
        with (
            patch("sys.argv", argv),
            patch("subprocess.Popen", side_effect=process),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            runpy.run_path(str(script), run_name="__main__")

    def test_full_cohort_requires_the_specific_admission_refusal(self):
        self.run_harness()
        with self.assertRaises(AssertionError):
            self.run_harness(failure_code="malformed_source")
        with self.assertRaises(AssertionError):
            self.run_harness(admit=True)

    def test_selected_run_must_succeed_even_in_the_largest_cohort(self):
        self.run_harness(selected=True, admit=True)
        with self.assertRaises(AssertionError):
            self.run_harness(selected=True)


if __name__ == "__main__":
    unittest.main()
