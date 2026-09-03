import { html, mount, rawHtml, toMarkup } from './preact.js';
import { highlightLisp } from './highlight.js';
import { privateEvidenceAbsence } from './private-evidence.js';

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

export function modelSessionDomId(streamId) {
  return `model-session-${safeClass(streamId || 'unknown')}`;
}

export function streamPresentation(stream) {
  const turns = Array.isArray(stream?.turns) ? stream.turns : [];
  const missions = [];
  for (const turn of turns) {
    for (const program of turn?.generated || []) {
      if (
        program?.['association_ambiguous?'] !== true &&
        typeof program?.mission_name === 'string' &&
        !missions.includes(program.mission_name)
      ) {
        missions.push(program.mission_name);
      }
    }
  }

  const programs = turns.reduce(
    (count, turn) => count + (turn?.generated || []).filter(presentableProgram).length,
    0,
  );
  return {
    label: missions.length ? missions.join(' → ') : stream?.stream_id || 'model session',
    streamId: stream?.stream_id || '',
    turns: turns.length,
    programs,
    outcome: String(turns.at(-1)?.outcome || 'incomplete'),
  };
}

function Conversation({ conversation }) {
  if (!conversation) return null;

  const streams = conversation.streams || [];
  const unavailable = conversation['available?'] === false;
  const incomplete = conversation['complete?'] === false;
  const ambiguous = conversation['ambiguous?'] === true;
  const configuration = unavailable
    ? privateEvidenceAbsence(conversation.reason)
    : undefined;
  const status = unavailable
    ? (configuration ? configuration.status : `Unavailable (HTTP ${conversation.status || 'error'})`)
    : `${streams.length} model session${streams.length === 1 ? '' : 's'}`;

  return html`
    <section class="inspection-panel semantic-conversation">
      <div class="inspection-heading">
        <div><span>Private analysis</span><h3>Model sessions & programs</h3></div>
        <strong>${status}</strong>
      </div>
      <p class="inspection-counts">
        What each model received, generated, and saw again as tool feedback. One turn means the model was called once; a successful first program needs no correction turn. Raw records remain available inside each turn.
      </p>
      ${unavailable && configuration && html`
        <div class="inspection-sensitivity">${configuration.cause}</div>`}
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
      <div class="semantic-streams">
        ${streams.map(stream => html`<${ModelStream} key=${stream.stream_id} stream=${stream} />`)}
      </div>
    </section>`;
}

function ModelStream({ stream }) {
  const presentation = streamPresentation(stream);
  return html`
    <details class="semantic-stream" id=${modelSessionDomId(presentation.streamId)}>
      <summary>
        <span class="semantic-stream-main">
          <strong>${presentation.label}</strong>
          ${presentation.streamId && presentation.label !== presentation.streamId && html`
            <code>${presentation.streamId}</code>`}
        </span>
        <span class="semantic-stream-meta">
          ${plural(presentation.turns, 'turn')} · ${plural(presentation.programs, 'program')} · ${presentation.outcome}
        </span>
      </summary>
      <div class="semantic-stream-body">
        ${(stream.turns || []).map(turn => html`
          <${ModelTurn} key=${turn.request_sequence ?? turn.turn} turn=${turn} />`)}
      </div>
    </details>
  `;
}

function ModelTurn({ turn }) {
  const generated = turn.generated || [];
  const programs = generated.filter(presentableProgram);
  const ambiguousPrograms = generated.length - programs.length;
  const messages = turn.messages_added || [];
  const feedback = turn.feedback || [];
  const promptMessages = messages.filter(message => message?.role !== 'tool');
  return html`
    <details class="kt-turn semantic-turn" open>
      <summary class="kt-turn-header">
        <strong>Turn ${turn.turn ?? '?'}</strong>
        <span class="kt-turn-meta">
          ${plural(programs.length, 'program')} · ${String(turn.outcome || 'incomplete')}
        </span>
      </summary>
      <div class="semantic-turn-body">
        <${SystemPrompt} turn=${turn} />
        ${promptMessages.length > 0 && html`
          <section class="kt-turn-in">
            <div class="kt-turn-label">Input added this turn</div>
            ${promptMessages.map((message, index) => html`
              <${Message} key=${message?.id || index} message=${message} />`)}
          </section>`}
        <${AssistantOutput} assistant=${turn.assistant} />
        ${programs.length > 0 && html`
          <section class="kt-turn-out">
            <div class="kt-turn-label">Generated programs</div>
            ${programs.map((program, index) => html`
              <div class="kt-program" key=${program?.evaluation_id || index}>
                <div class="kt-program-label">
                  ${program?.mission_name ? `${program.mission_name} · ` : ''}${program?.evaluation_id || `program ${index + 1}`}
                </div>
                ${rawHtml('pre', 'kt-code kt-code-lisp', highlightLisp(program?.source || ''))}
              </div>`)}
          </section>`}
        ${feedback.length > 0 && html`
          <section class="kt-turn-in semantic-feedback">
            <div class="kt-turn-label">Tool feedback in this turn</div>
            ${feedback.map((message, index) => html`
              <${Message} key=${message?.tool_call_id || index} message=${message} />`)}
          </section>`}
        ${ambiguousPrograms > 0 && html`
          <p class="semantic-association-warning">
            ${plural(ambiguousPrograms, 'generated source')} had an ambiguous turn association and appears only in the raw record.
          </p>`}
        ${turn.tokens && html`
          <div class="semantic-token-summary">Tokens: ${compactValue(turn.tokens)}</div>`}
        <details class="semantic-raw-turn">
          <summary>Raw turn record</summary>
          <pre>${displayValue({
            system: turn.system,
            messages_added: turn.messages_added,
            assistant: turn.assistant,
            generated: turn.generated,
            feedback: turn.feedback,
            tokens: turn.tokens,
            outcome: turn.outcome
          })}</pre>
        </details>
      </div>
    </details>
  `;
}

function SystemPrompt({ turn }) {
  if (!Object.prototype.hasOwnProperty.call(turn, 'system')) {
    return html`<p class="kt-prompt-same">System prompt unchanged from the previous turn.</p>`;
  }
  if (turn.system == null) {
    return html`<p class="kt-prompt-same">No system prompt was sent.</p>`;
  }

  return html`
    <details class="kt-system-prompt">
      <summary>System prompt <span>model input</span></summary>
      <pre class="kt-code">${displayValue(turn.system)}</pre>
    </details>
  `;
}

function AssistantOutput({ assistant }) {
  if (!assistant) return null;
  const content = assistant.content;
  const reasoning = assistant.reasoning;
  if (content == null && reasoning == null) return null;

  return html`
    <section class="kt-turn-out">
      <div class="kt-turn-label">Model response</div>
      ${reasoning != null && html`
        <div class="kt-msg kt-msg-reasoning">
          <span class="kt-msg-role">Reasoning</span>
          <div class="kt-msg-content">${displayValue(reasoning)}</div>
        </div>`}
      ${content != null && html`
        <div class="kt-msg kt-msg-assistant">
          <span class="kt-msg-role">Assistant</span>
          <div class="kt-msg-content">${displayValue(content)}</div>
        </div>`}
    </section>
  `;
}

function Message({ message }) {
  const role = message?.role || 'message';
  return html`
    <div class=${`kt-msg kt-msg-${safeClass(role)}`}>
      <span class="kt-msg-role">${role}</span>
      <div class="kt-msg-content">${displayValue(message?.content ?? message)}</div>
    </div>
  `;
}

function presentableProgram(program) {
  return program?.['association_ambiguous?'] !== true;
}

function displayValue(value) {
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value ?? null, null, 2);
  } catch (_error) {
    return String(value);
  }
}

function compactValue(value) {
  try {
    return JSON.stringify(value);
  } catch (_error) {
    return String(value);
  }
}

function plural(count, noun) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

function safeClass(value) {
  return String(value).replace(/[^a-z0-9-]/gi, '-').toLowerCase();
}
