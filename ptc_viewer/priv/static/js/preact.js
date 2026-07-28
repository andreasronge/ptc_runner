// Single import point for the vendored Preact runtime.
//
// The viewer has no build step: `priv/static` is served verbatim by Plug and
// the same modules are imported directly by node in the render test harness.
// Everything below is plain ESM with relative specifiers, so both environments
// resolve it without a bundler, an import map, or `node_modules`.
//
// Why a framework at all: the previous renderer rebuilt whole subtrees with
// `innerHTML`, which discarded every `<details open>` and the scroll position
// on each re-render, and it relied on remembering `escapeHtml` at ~150
// interpolation sites. Preact's keyed diff preserves DOM identity across
// re-renders and `html` escapes interpolated values by construction.
import { h, render as renderDom, Fragment } from './vendor/preact/preact.mjs';
import htm from './vendor/preact/htm.mjs';
import { render as renderToString } from './vendor/preact/render-to-string.mjs';

export { h, renderDom, renderToString, Fragment };
export * from './vendor/preact/hooks.mjs';

/** Tagged template producing Preact VDOM. Interpolated values are escaped. */
export const html = htm.bind(h);

/**
 * Embed pre-escaped HTML produced by a pure string transform (the syntax
 * highlighter). Only ever call this with output that is already HTML-safe;
 * everything else must go through `html` interpolation.
 */
export function rawHtml(tag, className, markup) {
  return h(tag, { class: className, dangerouslySetInnerHTML: { __html: markup } });
}

/** Render a component tree to a container, diffing against what is there. */
export function mount(container, vnode) {
  renderDom(vnode, container);
}

/** Render a component tree to an HTML string (used by the test harness). */
export function toMarkup(vnode) {
  return renderToString(vnode);
}
