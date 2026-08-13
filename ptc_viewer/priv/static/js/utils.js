// Small shared helpers. Rendering moved to Preact components, so the former
// HTML-string helpers (manual escaping, markup-returning badge builders) are
// gone: interpolation is escaped by the `html` tag instead.

export function truncate(str, len) {
  return str && str.length > len ? str.slice(0, len) + '...' : str || '';
}
