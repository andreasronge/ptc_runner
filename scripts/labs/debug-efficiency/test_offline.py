import copy
import json
from pathlib import Path
import unittest

import offline


FIXTURE = json.loads(Path(__file__).with_name("fixture.json").read_text())


class OfflineContractTest(unittest.TestCase):
    def test_fixed_response_requires_recorded_dispatch(self):
        case = copy.deepcopy(FIXTURE["cases"][0])
        case["arms"]["fixed"]["attempts"] = []
        with self.assertRaisesRegex(ValueError, "accepted dispatched attempt"):
            offline.score_case(case, "fixed")

    def test_known_rejection_and_unknown_failure_remain_in_accounting(self):
        result = offline.run(FIXTURE)["fixed"]
        self.assertEqual(result["known_cost_microusd"], 52)
        self.assertEqual(result["unknown_cost_attempts"], 1)
        self.assertFalse(result["total_cost_known"])
        self.assertEqual(result["outcomes"]["failure"], 3)


if __name__ == "__main__":
    unittest.main()
