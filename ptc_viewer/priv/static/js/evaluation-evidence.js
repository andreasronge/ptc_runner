// Shared public evaluator-evidence line for live cards and the kernel transcript.
// Kind and message are rendered only when both authenticated string fields are present.

export function evaluationPresentation(error) {
  if (!error || typeof error !== 'object') return null;
  const kind = error.kind;
  const message = error.message;
  if (typeof kind !== 'string' || typeof message !== 'string') return null;
  if (kind === '' || message === '') return null;
  return `evaluation: ${kind}: ${message}`;
}
