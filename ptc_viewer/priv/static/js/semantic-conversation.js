import { html, mount, toMarkup } from './preact.js';

export function renderSemanticConversation(container, conversation) {
  const existingHost = container.querySelector('.semantic-conversation-wrapper');

  if (!conversation) {
    if (existingHost) {
      mount(existingHost, null);
      existingHost.remove();
    }
    return;
  }

  const host = existingHost || container.appendChild(Object.assign(document.createElement('section'), {
    className: 'semantic-conversation-wrapper'
  }));
  mount(host, html`<${Conversation} conversation=${conversation} />`);
}

export function renderSemanticConversationMarkup(conversation) {
  if (!conversation) return '';
  return toMarkup(html`<${Conversation} conversation=${conversation} />`);
}

// Reasons the Viewer can state as a configuration change rather than a
// failure. A run of a project that records no inspection artifact is the
// common case, and an HTTP status is the wrong thing to show a reader for it.
const CONFIGURATION_REASONS = new Map([
  ['inspection_not_configured', {
    status: 'Not recorded',
    copy: 'This project does not record inspection artifacts. Set "trace" and "inspection" to true under "artifacts" in ptc-project.json and run again.'
  }]
]);

function Conversation({ conversation }) {
  if (!conversation) return null;

  const streams = conversation.streams || [];
  const unavailable = conversation['available?'] === false;
  const incomplete = conversation['complete?'] === false;
  const ambiguous = conversation['ambiguous?'] === true;
  const configuration = unavailable
    ? CONFIGURATION_REASONS.get(String(conversation.reason || '').trim())
    : undefined;
  const status = unavailable
    ? (configuration ? configuration.status : `Unavailable (HTTP ${conversation.status || 'error'})`)
    : `${streams.length} stream(s)`;

  return html`
    <section class="inspection-panel semantic-conversation">
      <div class="inspection-heading">
        <div><span>Private analysis</span><h3>Model conversation</h3></div>
        <strong>${status}</strong>
      </div>
      ${unavailable && configuration && html`
        <div class="inspection-sensitivity">${configuration.copy}</div>`}
      ${unavailable && !configuration && html`
        <div class="inspection-sensitivity">
          Private conversation unavailable: ${conversation.reason || 'the analysis request failed'}.
        </div>`}
      ${!unavailable && incomplete && html`
        <div class="inspection-sensitivity">
          Incomplete private evidence. ${conversation.missing_exchange_count || 0} expected model exchange(s) are missing.
        </div>`}
      ${!unavailable && ambiguous && html`
        <div class="inspection-sensitivity">
          Ambiguous conversation branches were not guessed into a stream.
        </div>`}
      ${!unavailable && !streams.length && !incomplete && html`
        <div class="inspection-counts">No model exchanges were captured for this run.</div>`}
      ${streams.map(stream => html`
        <div class="inspection-record" key=${stream.stream_id}>
          <h4>${stream.stream_id}</h4>
          ${stream.turns.map(turn => html`
            <details key=${turn.request_sequence} open>
              <summary>Turn ${turn.turn}</summary>
              <pre>${JSON.stringify({
                messages_added: turn.messages_added,
                assistant: turn.assistant,
                generated: turn.generated,
                feedback: turn.feedback,
                tokens: turn.tokens,
                outcome: turn.outcome
              }, null, 2)}</pre>
            </details>`)}
        </div>`)}
    </section>`;
}
