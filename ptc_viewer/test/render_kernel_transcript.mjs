import fs from 'node:fs';
import { renderKernelTranscriptMarkup } from '../priv/static/js/kernel-transcript.js';

const [inputPath] = process.argv.slice(2);
if (!inputPath) throw new Error('usage: node render_kernel_transcript.mjs INPUT');

process.stdout.write(renderKernelTranscriptMarkup(JSON.parse(fs.readFileSync(inputPath, 'utf8'))));
