"""Verify completed-prefix measurements, without treating the stopped case as replayed."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent
live = json.loads((root / 'live/results.json').read_text())
replay = json.loads((root / 'replay/results.json').read_text())
fields = ['experiment', 'subject', 'seed', 'ground_truth', 'candidates', 'solved', 'winner', 'selection']
assert len(live) == len(replay) == 1
for actual, repeated in zip(live, replay):
    for field in fields:
        assert actual[field] == repeated[field], field
    assert actual['usage']['llm_spend'] == repeated['usage']['llm_spend']
result = {
    'completed_cases_verified': len(live),
    'comparison_fields': fields + ['usage.llm_spend'],
    'equal': True,
    'excluded_fields': ['run_ref', 'wall_ms', 'console', 'non-model run bookkeeping'],
    'timeout_case_replayed': False,
    'full_matrix_replayed': False,
    'replay_exit_reason': 'missing fixture for unreplayable timeout; expected partial-run boundary',
}
(root / 'replay-verification.json').write_text(json.dumps(result, indent=2) + '\n')
print('Completed-prefix replay matches; timeout case was not replayed.')
