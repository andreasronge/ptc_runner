"""Build a report from retained harness output, never from inferred observations."""
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent
read = lambda path: json.loads((root / path).read_text())
summary = read('live/summary.json')
rows = read('live/results.json')
ledger = read('authorization-and-budget.json')
known = sum(row['usage']['llm_spend']['total_cost']['microunits'] for row in rows)
assert all(row['usage']['llm_spend']['state'] == 'available' for row in rows)
assert len(rows) == summary['completed_cases']
observations = []
for row in rows:
    item = {key: row[key] for key in ['experiment', 'subject', 'instance', 'seed', 'solved', 'winner', 'wall_ms']}
    item['llm_spend'] = row['usage']['llm_spend']
    item['candidates'] = []
    for candidate in row['candidates']:
        retained = {key: value for key, value in candidate.items() if key != 'candidate_source'}
        source = candidate.get('candidate_source')
        retained['candidate_source_sha256'] = hashlib.sha256(source.encode()).hexdigest() if source is not None else None
        item['candidates'].append(retained)
    observations.append(item)
result = {
    'schema_version': 1,
    'experiment': ledger['experiment'],
    'kind': 'measure',
    'purpose': ledger['kind'],
    'source_commit': read('invocation.json')['source_commit'],
    'status': 'completed' if summary['stop_reason'] is None else 'stopped',
    'protocol': read('live/protocol.json'),
    'completion': read('completion.json'),
    'summary': summary,
    'observations': observations,
    'raw_results_sha256': hashlib.sha256((root / 'live/results.json').read_bytes()).hexdigest(),
    'replay_verification': read('replay-verification.json'),
    'budget': {
        **ledger,
        'known_completed_case_cost_microusd': known,
        'retained_failed_case_reservation_microusd': summary['spent_or_reserved_microusd'] - known,
        'remaining_microusd': ledger['corrective_allowance_microusd'] - ledger['prior_spent_or_reserved_microusd'] - summary['spent_or_reserved_microusd'],
    },
    'verdict': 'stopped' if summary['stop_reason'] is not None else 'inconclusive',
    'hypotheses': [],
}
if ledger['kind'] != 'deadline_calibration':
    result['hypotheses'].append({
        'id': 'H1',
        'metric': 'paired final-test pass-rate difference',
        'assessment': 'inconclusive',
        'assessment_scope': 'descriptive completed pairs only; incomplete outcome-dependent prefix',
        'baseline_condition': 'E1 three-turn',
        'tolerance': 0.03,
        'decision_rule': {
            'version': 'prelude-search-corrective-2026-09-19',
            'source': 'docs/research/prelude-search.md#corrective-experiment-protocol',
            'support': '95% paired interval lower bound > 0.03',
            'rule_out_useful_improvement': '95% paired interval upper bound < 0.03',
            'equivalence': 'entire interval inside [-0.03, 0.03]',
            'otherwise': 'inconclusive',
            'pilot_constraint': 'No automatic verdict; stopped prefix does not establish population effects.',
        },
        'comparisons': [
            {
                **comparison,
                'denominators': {'observed': len(comparison['pairs']), 'baseline': len(comparison['pairs'])},
            }
            for comparison in summary['comparisons']
        ],
    })
if (root / 'latency-verification.json').exists():
    result['latency_verification'] = read('latency-verification.json')
if (root / 'analysis-findings.json').exists():
    result['analysis_findings'] = read('analysis-findings.json')
if (root / 'stopped-case-analysis.json').exists():
    result['stopped_case_analysis'] = read('stopped-case-analysis.json')
(root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'status':result['status'], 'completed':len(rows), 'remaining_microusd':result['budget']['remaining_microusd']}))
