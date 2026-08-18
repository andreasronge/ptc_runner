import assert from 'node:assert/strict';
import {
  displayRunName,
  emptyRunsMessage,
  excludedTraceNote,
  formatRunUsage,
  searchableRunFields
} from '../priv/static/js/run-display.js';

const run = {
  run_id: 'cmd-616240gsqd5q3hrzd857ar9xzh',
  name: `sha256:${'a'.repeat(64)}`,
  tags: { mode: 'agent' },
  llm_usage_total: { input: 12345, output: 678, total_cost: 0.0042 }
};

const matchingProject = { name: 'chief-of-staff-02-granting-data', name_fingerprint: run.name };
assert.equal(displayRunName(run, matchingProject), 'chief-of-staff-02-granting-data');
assert.equal(displayRunName(run, { name: 'another-project', name_fingerprint: `sha256:${'b'.repeat(64)}` }), run.run_id);
assert.equal(displayRunName({ ...run, name: 'readable-legacy-name' }, null), 'readable-legacy-name');

assert.deepEqual(formatRunUsage(run.llm_usage_total), [
  '12,345 in',
  '678 out',
  'cost 0.0042'
]);
assert.deepEqual(formatRunUsage({ input: 0, output: 0, total_cost: 0 }), [
  '0 in',
  '0 out',
  'cost 0'
]);
assert.deepEqual(formatRunUsage({ input: 7 }), ['7 in']);
assert.deepEqual(formatRunUsage(null), []);

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

process.stdout.write('ok');
