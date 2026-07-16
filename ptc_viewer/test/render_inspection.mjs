import fs from 'node:fs';
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

const path = process.argv[2];

if (!path) {
  throw new Error('usage: node render_inspection.mjs ARTIFACT');
}

const records = fs.readFileSync(path, 'utf8')
  .split('\n')
  .filter(Boolean)
  .map(line => JSON.parse(line));

process.stdout.write(renderInspectionMarkup({ records }));
