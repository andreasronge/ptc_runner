import assert from 'node:assert/strict';
import { fmtLimit, plural, uniqueComponents } from '../priv/static/js/live.js';

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

process.stdout.write('ok');
