import assert from 'node:assert/strict';
import {
  fmtLimit,
  formatLiveSpend,
  failurePresentation,
  launchPollDelay,
  launchStatusPresentation,
  leadingLimitRows,
  limitNote,
  limitSummary,
  liveReadPath,
  liveTokenFromSearch,
  missionNames,
  plural,
  projectDisplayPath,
  runRoute,
  uniqueComponents
} from '../priv/static/js/live.js';

// Limits arrive as raw catalog rows; the panel is responsible for making them
// readable without inventing units it was not given.
assert.equal(fmtLimit(120000, 'milliseconds'), '120 000 ms');
assert.equal(fmtLimit(2000000, 'bytes'), '2 000 000 B');
assert.equal(fmtLimit(8000000, 'heap_words'), '8 000 000 words');
assert.equal(fmtLimit(16, 'count'), '16');
assert.equal(fmtLimit(999, 'count'), '999');
assert.equal(fmtLimit(null, 'count'), '–');
assert.equal(fmtLimit(undefined, undefined), '–');

assert.equal(plural(0, 'component'), '0 components');
assert.equal(plural(1, 'component'), '1 component');
assert.equal(plural(2, 'provider'), '2 providers');
assert.equal(
  projectDisplayPath({ project: '/work/demo/ptc-project.json', manifest: '/work/demo/ptc.json' }),
  '/work/demo/ptc-project.json'
);
assert.equal(projectDisplayPath({ manifest: '/work/demo/ptc.json' }), '/work/demo/ptc.json');

// A shipped prelude compiled by several environments is one entry, keeping
// the "components & preludes" list a set rather than a tally.
const environments = [
  {
    name: 'workflow',
    components: [
      { id: 'llm', library: true, source: '(ns llm)' },
      { id: 'demo.live', library: false, source: '(ns demo.live)' }
    ]
  },
  { name: 'triage', components: [{ id: 'llm', library: true, source: '(ns llm)' }] },
  { name: 'audit' }
];

assert.deepEqual(
  uniqueComponents(environments).map(component => component.id),
  ['llm', 'demo.live']
);

assert.deepEqual(uniqueComponents([]), []);
assert.deepEqual(uniqueComponents([{ name: 'empty', components: [] }]), []);

// Launch chips exist only for missions; the workflow chip is added by the
// panel itself, and a workflow-only project must produce no chips at all.
assert.deepEqual(
  missionNames({
    environments: [
      { name: 'workflow', kind: 'workflow' },
      { name: 'review', kind: 'mission' },
      { name: 'triage', kind: 'mission' }
    ]
  }),
  ['review', 'triage']
);

assert.deepEqual(missionNames({ environments: [{ name: 'workflow', kind: 'workflow' }] }), []);
assert.deepEqual(missionNames({ environments: [{ kind: 'mission' }] }), []);
assert.deepEqual(missionNames({}), []);
assert.deepEqual(missionNames(null), []);

assert.deepEqual(launchStatusPresentation({ status: 'ok', output_tail: '{"sum" 6}' }), {
  state: 'ok',
  line: 'Last launch completed (exit 0):',
  output: '{"sum" 6}'
});
assert.equal(launchStatusPresentation({ status: 'error' }).output, '(no output captured)');
assert.equal(launchPollDelay(true, { status: 'running' }), 1500);
assert.equal(launchPollDelay(false, null), 3000);
assert.equal(launchPollDelay(true, { status: 'ok' }), null);

assert.equal(liveTokenFromSearch('?live_token=container-secret&x=1'), 'container-secret');
assert.equal(liveTokenFromSearch('?live_token=token%2Bwith%2Bplus'), 'token+with+plus');
assert.equal(liveTokenFromSearch('?x=1'), null);
assert.equal(liveTokenFromSearch('?live_token='), null);
assert.equal(liveReadPath('/api/live/stream', null), '/api/live/stream');
assert.equal(
  liveReadPath('/api/live/stream', 'token+with/slash'),
  '/api/live/stream?live_token=token%2Bwith%2Fslash'
);

assert.equal(runRoute('cmd-abc/def'), '#/run/cmd-abc%2Fdef');

assert.equal(
  failurePresentation({
    phase: 'error',
    outcome_limit: 'parallel_timeout_ms',
    outcome_reason: 'parallel_timeout_ms limit 60000 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower'
  }),
  'Limit exceeded: parallel_timeout_ms limit 60000 ms was exceeded during execution; raise limits.parallel_timeout_ms in the manifest, and the installed host ceiling if it is lower'
);

// Every named ceiling reads as a limit, not only the three the old prefix list
// happened to carry.
assert.equal(
  failurePresentation({
    phase: 'error',
    outcome_limit: 'max_turns',
    outcome_reason: 'agent turn limit 4 was exceeded; raise max_turns in the agent configuration, or reduce the work per turn'
  }),
  'Limit exceeded: agent turn limit 4 was exceeded; raise max_turns in the agent configuration, or reduce the work per turn'
);

assert.equal(
  failurePresentation({ phase: 'error', outcome_reason: 'explicit_failure' }),
  'Failure reason: explicit_failure'
);
assert.equal(
  failurePresentation({
    phase: 'error',
    outcome_limit: 'run_duration_ms',
    outcome_reason: 'run_duration_ms limit 60000 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower'
  }),
  'Limit exceeded: run_duration_ms limit 60000 ms was exceeded during execution; raise limits.run_duration_ms in the manifest, and the installed host ceiling if it is lower'
);
assert.equal(failurePresentation({ phase: 'ok', outcome_reason: null }), null);

assert.deepEqual(formatLiveSpend(null), { state: 'empty', value: '–', fields: [] });
assert.deepEqual(formatLiveSpend({ state: 'empty' }), { state: 'empty', value: '–', fields: [] });
assert.deepEqual(formatLiveSpend({ state: 'incomplete', input: 0, output: 0, total_cost: 0 }), {
  state: 'incomplete',
  value: 'incomplete',
  fields: []
});
assert.deepEqual(formatLiveSpend({ state: 'unpriced', input: 3, output: 2 }), {
  state: 'unpriced',
  value: '3 in · 2 out',
  fields: ['3 in', '2 out']
});
assert.deepEqual(
  formatLiveSpend({ state: 'available', input: 12345, output: 678, total_cost: 0.0042 }),
  {
    state: 'available',
    value: '12,345 in · 678 out · cost 0.0042',
    fields: ['12,345 in', '678 out', 'cost 0.0042']
  }
);

const untouchedWithHeadroom = {
  name: 'run_duration_ms',
  effective: 30000,
  default: 30000,
  ceiling: 1800000,
  unit: 'milliseconds'
};
const movedBelowCeiling = {
  name: 'run_duration_ms',
  effective: 120000,
  default: 30000,
  ceiling: 1800000,
  unit: 'milliseconds'
};
const raisedToCeiling = {
  name: 'run_duration_ms',
  effective: 1800000,
  default: 30000,
  ceiling: 1800000,
  unit: 'milliseconds'
};
const protectedAtCeiling = {
  name: 'workflow_heap_words',
  effective: 8000000,
  default: 8000000,
  ceiling: 8000000,
  unit: 'heap_words'
};

assert.equal(limitNote(untouchedWithHeadroom), 'ceiling 1 800 000 ms');
assert.equal(limitNote(movedBelowCeiling), 'default 30 000 ms · ceiling 1 800 000 ms');
assert.equal(limitNote(raisedToCeiling), 'default 30 000 ms · at installed ceiling');
assert.equal(limitNote(protectedAtCeiling), 'at installed ceiling');

const catalog = [untouchedWithHeadroom, movedBelowCeiling, raisedToCeiling, protectedAtCeiling];
assert.deepEqual(
  leadingLimitRows(catalog).map(limit => limit.name),
  ['run_duration_ms', 'run_duration_ms', 'workflow_heap_words']
);
assert.equal(limitSummary(leadingLimitRows(catalog)), '2 differ from defaults · 2 at installed ceiling');
assert.equal(limitSummary(leadingLimitRows([untouchedWithHeadroom])), 'all at defaults');
assert.equal(
  limitSummary(leadingLimitRows([protectedAtCeiling])),
  '1 at installed ceiling'
);

const hostOnlyTimeout = {
  name: 'local_preflight_timeout_ms',
  effective: 5000,
  default: 5000,
  ceiling: null,
  unit: 'milliseconds'
};
assert.equal(limitNote(hostOnlyTimeout), '');
assert.deepEqual(leadingLimitRows([hostOnlyTimeout]), []);

process.stdout.write('ok');
