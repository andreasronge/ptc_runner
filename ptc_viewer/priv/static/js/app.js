import { parseJsonl, extractTraceId, detectTraceType, extractChildTraceIds } from './parser.js';
import { renderOverview } from './overview.js';
import { renderAgentView } from './agent-view.js';
import { initTooltip } from './tooltip.js';

function formatDate(isoString) {
  const d = new Date(isoString);
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// Global state
const state = {
  files: new Map(),        // filename -> { events, traceId, filename }
  plans: new Map(),        // filename -> plan data
  navStack: [],            // [{type, label, data}]
  currentFilename: null,
  selectedTurn: null
};

export function getState() { return state; }

// Navigation
export function navigateTo(entry) {
  state.navStack.push(entry);
  render();
}

export function navigateBack(index) {
  state.navStack = state.navStack.slice(0, index + 1);
  render();
}

export function navigateUp() {
  if (state.navStack.length > 0) {
    state.navStack.pop();
    render();
  }
}

// Rendering
function render() {
  const container = document.getElementById('view-container');
  container.innerHTML = '';
  updateBreadcrumb();

  if (state.navStack.length === 0) {
    // Show drop zone and file picker when no trace is loaded
    const dropZone = document.getElementById('drop-zone');
    if (dropZone) dropZone.style.display = '';
    const picker = document.getElementById('file-picker');
    if (picker) picker.classList.remove('collapsed');
    return;
  }

  // Hide drop zone and collapse file picker when viewing a trace
  const dropZone = document.getElementById('drop-zone');
  if (dropZone) dropZone.style.display = 'none';
  const picker = document.getElementById('file-picker');
  if (picker) picker.classList.add('collapsed');

  const current = state.navStack[state.navStack.length - 1];
  if (current.type === 'overview') {
    renderOverview(container, state, current.data);
  } else if (current.type === 'agent') {
    renderAgentView(container, state, current.data);
  }

  // Scroll to the top of the content
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function updateBreadcrumb() {
  const nav = document.getElementById('breadcrumb');
  if (state.navStack.length === 0) {
    nav.innerHTML = '';
    return;
  }

  let html = '<span class="breadcrumb-item breadcrumb-home" data-index="-1">Traces</span>';
  html += state.navStack.map((entry, i) => {
    const isLast = i === state.navStack.length - 1;
    return `<span class="breadcrumb-sep">/</span><span class="breadcrumb-item${isLast ? ' active' : ''}" data-index="${i}">${entry.label}</span>`;
  }).join('');

  nav.innerHTML = html;

  // Home link clears the nav stack
  nav.querySelector('.breadcrumb-home').addEventListener('click', () => {
    state.navStack = [];
    render();
  });

  nav.querySelectorAll('.breadcrumb-item:not(.active):not(.breadcrumb-home)').forEach(el => {
    el.addEventListener('click', () => navigateBack(parseInt(el.dataset.index)));
  });
}

// Keyboard
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') navigateUp();
});

// Initialization
function init() {
  initTooltip();
  setupDropZone();
  tryLoadFromApi();
}

function setupDropZone() {
  const dropZone = document.getElementById('drop-zone');
  const fileInput = document.getElementById('fileInput');
  const selectBtn = document.getElementById('selectFilesBtn');

  dropZone.addEventListener('dragover', (e) => { e.preventDefault(); dropZone.classList.add('dragover'); });
  dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
  dropZone.addEventListener('drop', (e) => {
    e.preventDefault();
    dropZone.classList.remove('dragover');
    loadFilesFromDrop(e.dataTransfer.files);
  });

  selectBtn.addEventListener('click', () => fileInput.click());
  fileInput.addEventListener('change', (e) => loadFilesFromDrop(e.target.files));
}

async function loadFilesFromDrop(files) {
  for (const file of files) {
    const text = await file.text();
    const events = parseJsonl(text);
    const traceId = extractTraceId(events);
    state.files.set(file.name, { events, traceId, filename: file.name });
  }
  autoNavigate();
}

function autoNavigate() {
  if (state.files.size === 0) return;
  // Find main trace (prefer non-child traces)
  const mainFile = [...state.files.entries()].find(([name]) => !name.startsWith('trace_'));
  const filename = mainFile ? mainFile[0] : [...state.files.keys()][0];
  const data = state.files.get(filename);
  state.currentFilename = filename;

  state.navStack = [];
  const traceType = detectTraceType(data.events);
  if (traceType === 'plan') {
    navigateTo({ type: 'overview', label: filename, data });
  } else {
    navigateTo({ type: 'agent', label: filename, data });
  }
}

async function tryLoadFromApi() {
  try {
    const resp = await fetch('/api/traces');
    if (resp.ok) {
      const traces = await resp.json();
      if (traces.length > 0) {
        setupFilePicker(traces);
      }
    }
  } catch {
    // Not running with API server, drag-drop only
  }
}

function setupFilePicker(traces) {
  if (!traces || traces.length === 0) return;
  state._traces = traces;
  const picker = document.getElementById('file-picker');
  picker.innerHTML = `
    <div class="file-picker-header" id="file-picker-toggle">
      <h3>Available Traces <span class="file-picker-count">${traces.length} files</span></h3>
      <span class="file-picker-expand">&#9662;</span>
    </div>
    <div class="file-picker-list">
      ${traces.map(t => `
        <div class="file-picker-item" data-filename="${t.filename}">
          <span class="filename">${t.filename}</span>
          <span class="file-meta">
            <span class="modified">${formatDate(t.modified)}</span>
            <span class="size">${(t.size / 1024).toFixed(1)} KB</span>
          </span>
        </div>
      `).join('')}
    </div>
  `;
  picker.style.display = 'block';

  // Toggle collapsed state on header click
  picker.querySelector('#file-picker-toggle').addEventListener('click', () => {
    picker.classList.toggle('collapsed');
  });

  picker.querySelectorAll('.file-picker-item').forEach(item => {
    item.addEventListener('click', async () => {
      const filename = item.dataset.filename;
      // Show loading state
      item.classList.add('loading');
      await loadTraceFromApi(filename);
      item.classList.remove('loading');
    });
  });
}

function highlightActiveTrace(filename) {
  const picker = document.getElementById('file-picker');
  if (!picker) return;
  picker.querySelectorAll('.file-picker-item').forEach(item => {
    item.classList.toggle('active', item.dataset.filename === filename);
  });
}

async function loadTraceFromApi(filename) {
  const resp = await fetch(`/api/traces/${filename}`);
  if (!resp.ok) return;
  const text = await resp.text();
  const events = parseJsonl(text);
  const traceId = extractTraceId(events);
  state.files.set(filename, { events, traceId, filename });
  state.currentFilename = filename;

  // Also try to load child traces
  const childIds = extractChildTraceIds(events);
  for (const childId of childIds) {
    const childFilename = 'trace_' + childId + '.jsonl';
    if (state.files.has(childFilename)) continue;
    try {
      const childResp = await fetch(`/api/traces/${childFilename}`);
      if (childResp.ok) {
        const childText = await childResp.text();
        const childEvents = parseJsonl(childText);
        const childTraceId = extractTraceId(childEvents);
        state.files.set(childFilename, { events: childEvents, traceId: childTraceId, filename: childFilename });
      }
    } catch {
      // Ignore missing child traces
    }
  }

  highlightActiveTrace(filename);

  const traceType = detectTraceType(events);
  state.navStack = [];
  if (traceType === 'plan') {
    navigateTo({ type: 'overview', label: filename, data: state.files.get(filename) });
  } else {
    navigateTo({ type: 'agent', label: filename, data: state.files.get(filename) });
  }
}

// Export for other modules
export { state, render };

init();
