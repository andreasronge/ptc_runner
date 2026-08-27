import assert from 'node:assert/strict';
import {
  displayRunName,
  damagedTraceNote,
  emptyRunsMessage,
  excludedTraceNote,
  formatRunSpend,
  searchableRunFields,
  traceSourceNotes,
  validSpend
} from '../priv/static/js/run-display.js';

const run = {
  run_id: 'cmd-616240gsqd5q3hrzd857ar9xzh',
  name: `sha256:${'a'.repeat(64)}`,
  tags: { mode: 'agent' },
  llm_spend: {
    state: 'available', input: 12345, output: 678,
    total_cost: { currency: 'USD', microunits: 4200 }
  }
};

const matchingProject = { name: 'chief-of-staff-02-granting-data', name_fingerprint: run.name };
assert.equal(displayRunName(run, matchingProject), 'chief-of-staff-02-granting-data');
assert.equal(displayRunName(run, { name: 'another-project', name_fingerprint: `sha256:${'b'.repeat(64)}` }), run.run_id);
assert.equal(displayRunName({ ...run, name: 'readable-legacy-name' }, null), 'readable-legacy-name');

assert.deepEqual(formatRunSpend(run.llm_spend), [
  '12,345 in',
  '678 out',
  'cost 0.0042'
]);

const overflowSpend = { state: 'overflow' };
assert.equal(validSpend(overflowSpend), true);
assert.deepEqual(formatRunSpend(overflowSpend), ['usage overflow']);
assert.deepEqual(formatRunSpend({
  state: 'available', input: 0, output: 0,
  total_cost: { currency: 'USD', microunits: 0 }
}), [
  '0 in',
  '0 out',
  'cost 0'
]);
assert.deepEqual(formatRunSpend({ state: 'unpriced', input: 7, output: 2 }), [
  '7 in',
  '2 out',
  'cost unavailable'
]);
assert.deepEqual(formatRunSpend({ state: 'incomplete' }), ['usage incomplete']);
assert.deepEqual(formatRunSpend({ state: 'empty' }), []);
assert.deepEqual(formatRunSpend({
  state: 'unpriced', input: 7, output: 2,
  total_cost: { currency: 'USD', microunits: 0 }
}), []);
assert.deepEqual(formatRunSpend(null), []);

assert(searchableRunFields(run, matchingProject).includes('chief-of-staff-02-granting-data'));
assert(searchableRunFields(run, matchingProject).includes('agent'));

// An empty listing must not claim the directory is empty when the source kind
// withheld every run in it.
assert.equal(
  emptyRunsMessage({ items: [], omitted_count: 0 }),
  'No canonical runs in this trace directory.'
);

assert.equal(
  emptyRunsMessage({ items: [], omitted_count: 0, excluded_private_trace_files: 3 }),
  '3 private trace files excluded — set "viewer": { "private": true } in ptc-project.json to read them.'
);

assert.equal(
  excludedTraceNote({ excluded_private_trace_files: 1 }),
  '1 private trace file excluded — set "viewer": { "private": true } in ptc-project.json to read them.'
);

assert.equal(
  excludedTraceNote({ excluded_sanitized_trace_files: 2 }),
  '2 sanitized trace files excluded — this Viewer reads private traces only.'
);

// Pagination is a different number, and an absent or unusable count is not an
// exclusion to report.
assert.equal(excludedTraceNote({ omitted_count: 12 }), null);
assert.equal(excludedTraceNote({ excluded_private_trace_files: 0 }), null);
assert.equal(excludedTraceNote({ excluded_private_trace_files: '3' }), null);
assert.equal(excludedTraceNote(null), null);

const isolation = {
  component_count: 2,
  source_count: 3,
  known_run_count: 4,
  reasons: [],
  examples: [],
  examples_omitted_count: 2
};

assert.equal(
  damagedTraceNote({ isolation }),
  '3 damaged trace sources isolated in 2 components; 4 known runs are unavailable.'
);
assert.equal(damagedTraceNote({ isolation: { ...isolation, source_count: '3' } }), null);
assert.equal(damagedTraceNote(null), null);

assert.deepEqual(
  traceSourceNotes({ isolation, excluded_private_trace_files: 1 }),
  [
    '3 damaged trace sources isolated in 2 components; 4 known runs are unavailable.',
    '1 private trace file excluded — set "viewer": { "private": true } in ptc-project.json to read them.'
  ]
);

assert.equal(
  emptyRunsMessage({ items: [], omitted_count: 0, isolation }),
  '3 damaged trace sources isolated in 2 components; 4 known runs are unavailable.'
);

process.stdout.write('ok');
