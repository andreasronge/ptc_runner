const FINGERPRINT = /^sha256:[0-9a-f]{64}$/;

export function displayRunName(run, project) {
  if (project?.name && project?.name_fingerprint && run?.name === project.name_fingerprint) {
    return project.name;
  }

  if (typeof run?.name === 'string' && !FINGERPRINT.test(run.name)) return run.name;
  return run?.run_id || 'Unknown run';
}

export function formatRunSpend(spend) {
  if (spendExceedsDisplayRange(spend)) return ['usage exceeds display range'];
  if (!validSpend(spend)) return [];
  if (spend.state === 'empty') return [];
  if (spend.state === 'incomplete') return ['usage incomplete'];

  const fields = [];
  fields.push(`${spend.input.toLocaleString('en-US')} in`);
  fields.push(`${spend.output.toLocaleString('en-US')} out`);

  if (spend.state === 'available') {
    fields.push(`cost ${spend.total_cost.toLocaleString('en-US', { maximumSignificantDigits: 6 })}`);
  } else {
    fields.push('cost unavailable');
  }

  return fields;
}

export function validSpend(spend) {
  if (!spend || typeof spend !== 'object' || Array.isArray(spend)) return false;
  const keys = Object.keys(spend).sort();

  if (spend.state === 'empty' || spend.state === 'incomplete') {
    return keys.length === 1 && keys[0] === 'state';
  }

  if (!Number.isSafeInteger(spend.input) || spend.input < 0 ||
      !Number.isSafeInteger(spend.output) || spend.output < 0) return false;

  if (spend.state === 'unpriced') {
    return keys.join(',') === 'input,output,state';
  }

  return spend.state === 'available' &&
    keys.join(',') === 'input,output,state,total_cost' &&
    typeof spend.total_cost === 'number' && Number.isFinite(spend.total_cost) && spend.total_cost >= 0;
}

function spendExceedsDisplayRange(spend) {
  if (!spend || typeof spend !== 'object' || Array.isArray(spend)) return false;
  const keys = Object.keys(spend).sort().join(',');
  const tokens = [spend.input, spend.output];
  const integerTokens = tokens.every(value => Number.isInteger(value) && value >= 0);
  const unsafeTokens = tokens.some(value => !Number.isSafeInteger(value));

  if (!integerTokens || !unsafeTokens) return false;
  if (spend.state === 'unpriced') return keys === 'input,output,state';

  return spend.state === 'available' && keys === 'input,output,state,total_cost' &&
    typeof spend.total_cost === 'number' && Number.isFinite(spend.total_cost) && spend.total_cost >= 0;
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

export function damagedTraceNote(page) {
  const isolation = page?.isolation;
  if (!isolation || typeof isolation !== 'object' || Array.isArray(isolation)) return null;

  const components = countedIsolation(isolation.component_count);
  const sources = countedIsolation(isolation.source_count);
  const runs = nonNegativeIsolation(isolation.known_run_count);
  if (!components || !sources || runs === null) return null;

  return `${sources} damaged trace ${plural(sources, 'source')} isolated in ${components} ${plural(components, 'component')}; ${runs} known ${plural(runs, 'run')} ${runs === 1 ? 'is' : 'are'} unavailable.`;
}

export function traceSourceNotes(page) {
  return [damagedTraceNote(page), excludedTraceNote(page)].filter(Boolean);
}

export function emptyRunsMessage(page) {
  return traceSourceNotes(page).join(' ') || 'No canonical runs in this trace directory.';
}

function countedExclusion(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function countedIsolation(value) {
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function nonNegativeIsolation(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

function plural(count, noun) {
  return count === 1 ? noun : `${noun}s`;
}
