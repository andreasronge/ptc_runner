import { html, mount, toMarkup } from './preact.js';

export function renderSemanticConversation(container, conversation) {
  const host = container.querySelector('.semantic-conversation-wrapper') ||
    container.appendChild(Object.assign(document.createElement('section'), {
      className: 'semantic-conversation-wrapper'
    }));
  mount(host, html`<${Conversation} conversation=${conversation} />`);
}

export function renderSemanticConversationMarkup(conversation) {
  if (!conversation?.streams?.length) return '';
  return toMarkup(html`<${Conversation} conversation=${conversation} />`);
}

function Conversation({ conversation }) {
  if (!conversation?.streams?.length) return null;

  return html`
    <section class="inspection-panel semantic-conversation">
      <div class="inspection-heading">
        <div><span>Private analysis</span><h3>Model conversation</h3></div>
        <strong>${conversation.streams.length} stream(s)</strong>
      </div>
      ${conversation.streams.map(stream => html`
        <div class="inspection-record" key=${stream.stream_id}>
          <h4>${stream.stream_id}</h4>
          ${stream.turns.map(turn => html`
            <details key=${turn.request_sequence} open>
              <summary>Turn ${turn.turn}</summary>
              <pre>${JSON.stringify({
                system: turn.system,
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
