import { html, mount, toMarkup } from './preact.js';

// Index private inspection records by their canonical correlation IDs so the
// transcript and dialogue views can join exact payloads to canonical events.
export function indexInspection(inspection) {
  const byCapability = new Map();
  const byEvaluation = new Map();
  const byComponent = new Map();
  const conflicts = [];

  for (const record of inspection?.records || []) {
    const capabilityId = record.correlation?.capability_id;
    const evaluationId = record.correlation?.evaluation_id;
    const componentId = record.correlation?.component_id;

    if (capabilityId) {
      const entry = byCapability.get(capabilityId) || { input: null, output: null };
      if (record.record_type === 'capability-input') {
        if (entry.input) conflicts.push(`capability-input/${capabilityId}`);
        else entry.input = record;
      }
      if (record.record_type === 'capability-output') {
        if (entry.output) conflicts.push(`capability-output/${capabilityId}`);
        else entry.output = record;
      }
      byCapability.set(capabilityId, entry);
    } else if (evaluationId && record.record_type === 'evaluation-source') {
      if (byEvaluation.has(evaluationId)) conflicts.push(`evaluation-source/${evaluationId}`);
      else byEvaluation.set(evaluationId, record);
    } else if (componentId && record.record_type === 'prelude-source') {
      const mission = record.payload?.mission_name;
      const key = mission
        ? `${record.payload?.environment}/${mission}/${componentId}`
        : `${record.payload?.environment}/${componentId}`;
      if (byComponent.has(key)) conflicts.push(`prelude-source/${key}`);
      else byComponent.set(key, record);
    }
  }

  return {
    byCapability,
    byEvaluation,
    byComponent,
    conflicts,
    present: byCapability.size > 0 || byEvaluation.size > 0 || byComponent.size > 0
  };
}

export function renderInspection(container, inspection) {
  const host = container.querySelector('.inspection-wrapper') ||
    container.appendChild(Object.assign(document.createElement('section'), { className: 'inspection-wrapper' }));
  mount(host, html`<${InspectionRecords} inspection=${inspection} />`);
}

export function renderInspectionMarkup(inspection) {
  if (!(inspection?.records || []).length) return '';
  return toMarkup(html`<${InspectionRecords} inspection=${inspection} />`);
}

function InspectionRecords({ inspection }) {
  const records = inspection?.records || [];
  if (!records.length) return null;

  const counts = records.reduce((result, record) => {
    result[record.record_type] = (result[record.record_type] || 0) + 1;
    return result;
  }, {});
  const countSummary = Object.entries(counts)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([type, count]) => `${count} ${type}`)
    .join(' · ');

  return html`
    <details class="inspection-panel inspection-advanced">
      <summary class="inspection-heading">
        <div>
          <span>Private artifact</span>
          <h3>Advanced/private records</h3>
        </div>
        <strong>${records.length} records</strong>
      </summary>
      <div class="inspection-sensitivity">
        Sensitive private data from the pinned local artifact. Keep it local.
      </div>
      <div class="inspection-counts">${countSummary}</div>
      <div class="inspection-records">
        ${records.map(record => html`<${Record} key=${record.sequence} record=${record} />`)}
      </div>
    </details>
  `;
}

function Record({ record }) {
  const label = record.record_type === 'evaluation-source'
    ? record.payload?.program_kind || record.record_type
    : record.payload?.name || record.record_type;

  return html`
    <details class="inspection-record">
      <summary>
        <span>#${String(record.sequence)}</span>
        <strong>${String(record.record_type)}</strong>
        <code>${String(label)}</code>
      </summary>
      <pre>${JSON.stringify(record, null, 2)}</pre>
    </details>
  `;
}
