import { html, mount, toMarkup } from './preact.js';

export function renderSemanticConversation(container, conversation) {
  const host = container.querySelector('.semantic-conversation-wrapper') ||
    container.appendChild(Object.assign(document.createElement('section'), {
      className: 'semantic-conversation-wrapper'
    }));
  mount(host, html`<${Conversation} conversation=${conversation} />`);
}

export function renderSemanticConversationMarkup(conversation) {
  if (!conversation) return '';
  return toMarkup(html`<${Conversation} conversation=${conversation} />`);
}

function Conversation({ conversation }) {
  if (!conversation) return null;

  const streams = conversation.streams || [];
  const unavailable = conversation['available?'] === false;
  const incomplete = conversation['complete?'] === false;
  const ambiguous = conversation['ambiguous?'] === true;
  const status = unavailable
    ? `Unavailable (HTTP ${conversation.status || 'error'})`
    : `${streams.length} stream(s)`;

  return html`
    <section class="inspection-panel semantic-conversation">
      <div class="inspection-heading">
        <div><span>Private analysis</span><h3>Model conversation</h3></div>
        <strong>${status}</strong>
      </div>
      ${unavailable && html`
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
