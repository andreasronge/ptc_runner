// Page behaviour for the documentation pages: PTC-Lisp syntax highlighting
// and copy buttons on code blocks.
//
// Highlighting reuses the same vendored highlight.js core and Clojure grammar
// as the trace Viewer (BSD-3-Clause; the files under /vendor/highlightjs/ are
// copied verbatim from the Viewer by mix ptc.gen_site_guides).
// `hljs.highlight(...).value` HTML-escapes the source itself, so assigning it
// is safe.
import hljs from '/vendor/highlightjs/core.min.js';
import clojure from '/vendor/highlightjs/clojure.min.js';

hljs.registerLanguage('clojure', clojure);

for (const block of document.querySelectorAll('pre > code.language-clojure')) {
  block.innerHTML = hljs.highlight(block.textContent, {
    language: 'clojure',
    ignoreIllegal: true,
  }).value;
}

// Copy buttons. A REPL transcript copies as just its commands, prompts and
// printed results stripped, so the clipboard is ready to paste into a
// terminal; every other block copies verbatim.
function copyableText(code) {
  const text = code.textContent.replace(/\n$/, '');
  const commands = text.split('\n').filter((line) => line.startsWith('ptc> '));
  if (commands.length > 0) return commands.map((line) => line.slice(5)).join('\n');
  return text;
}

for (const pre of document.querySelectorAll('.guide-main pre')) {
  const code = pre.querySelector('code');
  if (!code) continue;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'copy-button';
  button.textContent = 'Copy';
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(copyableText(code));
      button.textContent = 'Copied';
    } catch {
      button.textContent = 'Press ⌘C';
      window.getSelection().selectAllChildren(code);
    }
    setTimeout(() => {
      button.textContent = 'Copy';
    }, 1600);
  });
  pre.appendChild(button);
}
