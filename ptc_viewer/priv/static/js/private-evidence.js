// Why authorized private evidence is absent, stated as a configuration change
// rather than a transport status.
//
// Prompts, responses, generated program source, and prelude component source
// are private evidence. Four separate decisions withhold them, each with a
// different next action, and an HTTP status names none of them. The Viewer
// serves the reason code as the response body so this table can turn it into
// the sentence that says what to change.
//
// Every panel that can go dark shares this table: the reason belongs to the
// run, not to one view of it, and two panels reporting the same absence
// differently would read as two different problems.

const CAUSES = new Map([
  ['inspection_not_configured', {
    status: 'Not recorded',
    cause: 'This project does not record inspection artifacts. Set "trace" and "inspection" to true under "artifacts" in ptc-project.json and run again.'
  }],
  ['inspection_not_private', {
    status: 'Not granted',
    cause: 'This project records inspection artifacts, but this Viewer was not granted them. Set "private" to true under "viewer" in ptc-project.json and start the Viewer again. The artifacts on disk are already usable; nothing needs to be re-run.'
  }],
  ['inspection_run_not_recorded', {
    status: 'Not recorded for this run',
    cause: 'This Viewer reads private evidence, but this run recorded none. A run made before "inspection" was enabled keeps only its canonical trace; run the project again to record one.'
  }],
  ['inspection_run_mismatch', {
    status: 'Other run',
    cause: 'This Viewer was started for a different run’s inspection artifact. Start it for this run to read this run’s private evidence.'
  }]
]);

// Returns `{status, cause}` for a known reason code, or `undefined` when the
// absence is a genuine failure the reader cannot resolve by changing a setting.
// Callers render the transport status for those, never a fabricated remedy.
export function privateEvidenceAbsence(reason) {
  return CAUSES.get(String(reason || '').trim());
}
