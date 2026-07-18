import fs from 'node:fs';
import { renderKernelTranscriptMarkup } from '../priv/static/js/kernel-transcript.js';
import { renderInspectionMarkup } from '../priv/static/js/inspection.js';

globalThis.document = {
  createElement() {
    return {
      set textContent(value) {
        this.innerHTML = String(value)
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      }
    };
  }
};

const [metadataPath, turnsPath, inspectionPath, inspectionStatusPath] = process.argv.slice(2);
if (!metadataPath || !turnsPath || !inspectionPath) {
  throw new Error('usage: node render_viewer.mjs METADATA TURNS INSPECTION');
}

const readJson = path => JSON.parse(fs.readFileSync(path, 'utf8'));
const metadata = readJson(metadataPath);
const turns = readJson(turnsPath);
const inspection = readJson(inspectionPath);
const inspectionStatus = inspectionStatusPath ? readJson(inspectionStatusPath) : null;

process.stdout.write(
  renderKernelTranscriptMarkup({ metadata, turns, inspection, inspectionStatus }) +
    renderInspectionMarkup(inspection)
);
