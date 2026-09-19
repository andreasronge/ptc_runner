"""Compare the recorded, completed prefix; do not synthesize stopped observations."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent
read = lambda name: json.loads((root / name).read_text())
live, replay = read('live/results.json'), read('replay/results.json')
summary = read('live/summary.json')
fields = ['experiment', 'subject', 'seed', 'ground_truth', 'candidates', 'solved', 'winner', 'selection']
assert len(live) == len(replay) == summary['completed_cases']
assert len(read('live/fixtures/index.json')) == len(live)
for actual, repeated in zip(live, replay):
    for field in fields:
        assert actual[field] == repeated[field], field
    assert actual['usage']['llm_spend'] == repeated['usage']['llm_spend']
assert read('replay/summary.json')['spent_or_reserved_microusd'] == 0
result = {
    'completed_cases_verified': len(live),
    'comparison_fields': fields + ['usage.llm_spend'],
    'equal': True,
    'excluded_fields': ['run_ref', 'wall_ms', 'console', 'non-model run bookkeeping'],
    'stopped_case_replayed': False,
    'full_matrix_replayed': summary['stop_reason'] is None,
    'replay_new_spend_microusd': 0,
}
(root / 'replay-verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
