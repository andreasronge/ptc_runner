import { escapeHtml } from './utils.js';

// Index private inspection records by their canonical correlation IDs so the
// transcript and dialogue views can join exact payloads to canonical events.
export function indexInspection(inspection) {
  const byCapability = new Map();
  const byEvaluation = new Map();
  const byComponent = new Map();

  for (const record of inspection?.records || []) {
    const capabilityId = record.correlation?.capability_id;
    const evaluationId = record.correlation?.evaluation_id;
    const componentId = record.correlation?.component_id;

    if (capabilityId) {
      const entry = byCapability.get(capabilityId) || { input: null, output: null };
      if (record.record_type === 'capability-input') entry.input = record;
      if (record.record_type === 'capability-output') entry.output = record;
      byCapability.set(capabilityId, entry);
    } else if (evaluationId && record.record_type === 'evaluation-source') {
      byEvaluation.set(evaluationId, record);
    } else if (componentId && record.record_type === 'prelude-source') {
      byComponent.set(`${record.payload?.environment}/${componentId}`, record);
    }
  }

  return {
    byCapability,
    byEvaluation,
    byComponent,
    present: byCapability.size > 0 || byEvaluation.size > 0 || byComponent.size > 0
  };
}

export function renderInspection(container, inspection) {
  const records = inspection?.records || [];
  if (!records.length) return;

  const section = document.createElement('section');
  section.className = 'inspection-panel';
  section.innerHTML = renderInspectionMarkup(inspection);
  container.appendChild(section);
}

export function renderInspectionMarkup(inspection) {
  const records = inspection?.records || [];
  if (!records.length) return '';

  return `
    <div class="inspection-warning" role="alert">
      <strong>Sensitive inspection data.</strong>
      This fixed private artifact contains full evaluated source and capability inputs and outputs.
      Keep it local and do not share it as a sanitized trace.
    </div>
    <div class="inspection-heading">
      <div>
        <span>Private artifact</span>
        <h3>Captured payloads</h3>
      </div>
      <strong>${records.length} records</strong>
    </div>
    <div class="inspection-records">
      ${records.map(renderRecord).join('')}
    </div>
  `;
}

function renderRecord(record) {
  const label = record.record_type === 'evaluation-source'
    ? record.payload?.program_kind || record.record_type
    : record.payload?.name || record.record_type;

  return `
    <details class="inspection-record">
      <summary>
        <span>#${escapeHtml(String(record.sequence))}</span>
        <strong>${escapeHtml(String(record.record_type))}</strong>
        <code>${escapeHtml(String(label))}</code>
      </summary>
      <pre>${escapeHtml(JSON.stringify(record, null, 2))}</pre>
    </details>
  `;
}
