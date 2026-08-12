import fs from 'node:fs';
import { renderKernelTranscriptMarkup } from '../priv/static/js/kernel-transcript.js';
import { renderSemanticConversationMarkup } from '../priv/static/js/semantic-conversation.js';

const [metadataPath, turnsPath, conversationPath] = process.argv.slice(2);
if (!metadataPath || !turnsPath || !conversationPath) {
  throw new Error('usage: node render_semantic_viewer.mjs METADATA TURNS CONVERSATION');
}

const readJson = path => JSON.parse(fs.readFileSync(path, 'utf8'));
const metadata = readJson(metadataPath);
const turns = readJson(turnsPath);
const conversation = readJson(conversationPath);

process.stdout.write(
  renderKernelTranscriptMarkup({ metadata, turns }) +
    renderSemanticConversationMarkup(conversation)
);
