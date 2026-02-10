import { escapeHtml } from './utils.js';

export function highlightLisp(code) {
  // Important: Use single quotes for HTML attributes to avoid conflict
  // with the double-quote string pattern in Lisp
  return escapeHtml(code)
    .replace(/;[^\n]*/g, "<span class='comment'>$&</span>")
    .replace(/\b(def|defn|let|if|cond|when|do|fn|loop|recur|return|fail|pmap|pcalls|doseq|for)\b/g, "<span class='keyword'>$1</span>")
    .replace(/\b(map|filter|reduce|first|rest|count|get|assoc|conj|into|take|drop|distinct|concat|str|println|inc|dec)\b/g, "<span class='builtin'>$1</span>")
    .replace(/"([^"\\]|\\.)*"/g, "<span class='string'>$&</span>")
    .replace(/\b(\d+\.?\d*)\b/g, "<span class='number'>$1</span>")
    .replace(/:([\w-]+)/g, "<span class='symbol'>:$1</span>")
    .replace(/data\/[\w-]+/g, "<span class='symbol'>$&</span>")
    .replace(/tool\/[\w-]+/g, "<span class='builtin'>$&</span>");
}
