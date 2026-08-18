const FINGERPRINT = /^sha256:[0-9a-f]{64}$/;

export function displayRunName(run, project) {
  if (project?.name && project?.name_fingerprint && run?.name === project.name_fingerprint) {
    return project.name;
  }

  if (typeof run?.name === 'string' && !FINGERPRINT.test(run.name)) return run.name;
  return run?.run_id || 'Unknown run';
}

export function formatRunUsage(usage) {
  if (!usage || typeof usage !== 'object') return [];

  const fields = [];
  if (Number.isSafeInteger(usage.input) && usage.input >= 0) fields.push(`${usage.input.toLocaleString('en-US')} in`);
  if (Number.isSafeInteger(usage.output) && usage.output >= 0) fields.push(`${usage.output.toLocaleString('en-US')} out`);
  if (typeof usage.total_cost === 'number' && Number.isFinite(usage.total_cost) && usage.total_cost >= 0) {
    fields.push(`cost ${usage.total_cost.toLocaleString('en-US', { maximumSignificantDigits: 6 })}`);
  }
  return fields;
}

export function searchableRunFields(run, project) {
  return [
    run?.run_id,
    run?.name,
    displayRunName(run, project),
    run?.status,
    run?.trace_id,
    run?.workflow_prelude?.hash,
    ...Object.entries(run?.tags || {}).flat()
  ].filter(field => typeof field === 'string');
}

// A trace directory holds sanitized and private artifacts, and one Viewer
// source grant reads exactly one kind. Reporting the runs it read as the runs
// that exist sent a tester hunting a rendering bug in a Viewer that was
// working, so name the files the grant refused to read and the setting that
// reads them.
export function excludedTraceNote(page) {
  const privateFiles = countedExclusion(page?.excluded_private_trace_files);
  const sanitizedFiles = countedExclusion(page?.excluded_sanitized_trace_files);

  if (privateFiles) {
    return `${privateFiles} private trace ${plural(privateFiles, 'file')} excluded — set "viewer": { "private": true } in ptc-project.json to read them.`;
  }

  if (sanitizedFiles) {
    return `${sanitizedFiles} sanitized trace ${plural(sanitizedFiles, 'file')} excluded — this Viewer reads private traces only.`;
  }

  return null;
}

export function emptyRunsMessage(page) {
  return excludedTraceNote(page) || 'No canonical runs in this trace directory.';
}

function countedExclusion(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function plural(count, noun) {
  return count === 1 ? noun : `${noun}s`;
}
