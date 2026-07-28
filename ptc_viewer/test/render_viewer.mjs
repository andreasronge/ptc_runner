import fs from 'node:fs';
import { renderKernelTranscriptMarkup } from '../priv/static/js/kernel-transcript.js';
import { renderInspectionMarkup } from '../priv/static/js/inspection.js';

// No DOM stub: the render path is `preact-render-to-string` over the same
// components the browser mounts, and the syntax highlighter is a pure string
// transform. Both run unmodified under plain node.

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
