import { renderKernelTranscript } from './kernel-transcript.js';
import { escapeHtml, truncate } from './utils.js';

function formatDate(isoString) {
  const date = new Date(isoString);
  const pad = value => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

const state = { currentRun: null };

function showNotice(message) {
  let notice = document.getElementById('viewer-notice');
  if (!notice) {
    notice = document.createElement('div');
    notice.id = 'viewer-notice';
    notice.className = 'viewer-notice';
    const picker = document.getElementById('file-picker');
    picker.parentNode.insertBefore(notice, picker);
  }
  notice.textContent = message;
  notice.style.display = '';
}

async function safeBodyText(response) {
  try {
    const text = await response.text();
    return truncate(text.trim() || response.statusText, 200);
  } catch {
    return response.statusText;
  }
}

async function loadRuns(cursor = null, priorRuns = []) {
  const suffix = cursor ? `&cursor=${encodeURIComponent(cursor)}` : '';
  const response = await fetch(`/api/kernel/runs?limit=100${suffix}`);

  if (!response.ok) {
    showNotice(`Canonical run listing failed (HTTP ${response.status}: ${await safeBodyText(response)}).`);
    return;
  }

  setupRunPicker(await response.json(), priorRuns);
}

function setupRunPicker(page, priorRuns = []) {
  const runs = [...priorRuns, ...(page.items || [])];
  const picker = document.getElementById('file-picker');
  picker.innerHTML = `
    <div class="file-picker-header" id="file-picker-toggle">
      <h3>Kernel Runs <span class="file-picker-count">${runs.length}${page.truncated ? '+' : ''} runs</span></h3>
      <span class="file-picker-expand">&#9662;</span>
    </div>
    <div class="file-picker-list">
      ${runs.map(run => `
        <div class="file-picker-item" data-run-id="${escapeHtml(run.run_id)}">
          <div class="file-picker-main">
            <span class="filename">${escapeHtml(run.name || run.run_id)}</span>
            <span class="file-meta">
              <span class="trace-kind badge-${run.status === 'ok' ? 'agent' : 'error'}">${escapeHtml(run.status || 'incomplete')}</span>
              ${run.start_timestamp ? `<span class="modified">${formatDate(run.start_timestamp)}</span>` : ''}
              <span class="size">${run.subordinate_evaluations || 0} evaluations</span>
            </span>
          </div>
          <div class="file-picker-query">${escapeHtml(run.run_id)}</div>
        </div>
      `).join('')}
      ${page.next_cursor ? '<button class="btn kernel-load-more" type="button">Load more runs</button>' : ''}
    </div>
  `;
  picker.style.display = 'block';
  picker.querySelector('#file-picker-toggle').addEventListener('click', () => picker.classList.toggle('collapsed'));
  picker.querySelectorAll('.file-picker-item').forEach(item => {
    item.addEventListener('click', async () => {
      item.classList.add('loading');
      await loadRun(item.dataset.runId);
      item.classList.remove('loading');
    });
  });
  picker.querySelector('.kernel-load-more')?.addEventListener('click', async event => {
    event.currentTarget.disabled = true;
    await loadRuns(page.next_cursor, runs);
  });
}

async function loadRun(runId) {
  const [runResponse, turnsResponse] = await Promise.all([
    fetch(`/api/kernel/runs/${encodeURIComponent(runId)}`),
    fetch(`/api/kernel/runs/${encodeURIComponent(runId)}/turns?limit=100`)
  ]);

  if (!runResponse.ok || !turnsResponse.ok) {
    const failed = runResponse.ok ? turnsResponse : runResponse;
    showNotice(`Failed to load run ${runId} (HTTP ${failed.status}: ${await safeBodyText(failed)}).`);
    return;
  }

  renderRun({ metadata: await runResponse.json(), turns: await turnsResponse.json() });
}

function renderRun(data) {
  state.currentRun = data;
  const { metadata, turns } = data;
  document.getElementById('breadcrumb').innerHTML = `
    <span class="breadcrumb-item breadcrumb-home">Runs</span>
    <span class="breadcrumb-sep">/</span>
    <span class="breadcrumb-item active">${escapeHtml(metadata.name || metadata.run_id)}</span>
  `;
  document.querySelector('.breadcrumb-home').addEventListener('click', () => {
    state.currentRun = null;
    document.getElementById('view-container').innerHTML = '';
    document.getElementById('breadcrumb').innerHTML = '';
  });

  renderKernelTranscript(document.getElementById('view-container'), data, {
    onLoadMore: async button => {
      button.disabled = true;
      button.textContent = 'Loading…';
      const response = await fetch(
        `/api/kernel/runs/${encodeURIComponent(metadata.run_id)}/turns?limit=100&cursor=${encodeURIComponent(turns.next_cursor)}`
      );

      if (!response.ok) {
        button.disabled = false;
        button.textContent = 'Load more events';
        return;
      }

      const nextPage = await response.json();
      renderRun({
        metadata,
        turns: { ...nextPage, items: [...(turns.items || []), ...(nextPage.items || [])] }
      });
    }
  });
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

loadRuns().catch(() => showNotice('Canonical run listing is unavailable.'));
