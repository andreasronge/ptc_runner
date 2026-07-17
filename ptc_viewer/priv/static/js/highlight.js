// PTC-Lisp / Clojure syntax highlighting via a vendored highlight.js core plus
// its Clojure grammar (BSD-3-Clause, priv/static/js/vendor/highlightjs/).
// `hljs.highlight(...).value` is a pure string transform that HTML-escapes the
// source, so the result is safe to embed directly inside a <pre> with no
// further escaping. It touches no DOM/`window` APIs, so it also runs under the
// minimal `document` stub the render test harness installs.
import hljs from './vendor/highlightjs/core.min.js';
import clojure from './vendor/highlightjs/clojure.min.js';

hljs.registerLanguage('clojure', clojure);

/**
 * Highlight a PTC-Lisp / Clojure source string into safe, escaped HTML wrapped
 * in `hljs-*` token spans. `ignoreIllegal` keeps malformed fragments from
 * throwing — they fall through as escaped text. Wrap the result in
 * `<pre class="kt-code kt-code-lisp">`.
 */
export function highlightLisp(source) {
  if (source == null || source === '') return '';
  return hljs.highlight(String(source), { language: 'clojure', ignoreIllegal: true }).value;
}
