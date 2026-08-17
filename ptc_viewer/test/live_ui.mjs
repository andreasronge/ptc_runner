import assert from 'node:assert/strict';
import {
  fmtLimit,
  failurePresentation,
  launchStatusPresentation,
  missionNames,
  plural,
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

assert.equal(runRoute('cmd-abc/def'), '#/run/cmd-abc%2Fdef');

assert.equal(
  failurePresentation({
    phase: 'error',
    outcome_reason: 'parallel_timeout_ms limit 60000 ms was exceeded during execution'
  }),
  'Limit exceeded: parallel_timeout_ms limit 60000 ms was exceeded during execution'
);
assert.equal(failurePresentation({ phase: 'ok', outcome_reason: null }), null);

process.stdout.write('ok');
