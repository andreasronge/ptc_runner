import { escapeHtml } from './utils.js';

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
