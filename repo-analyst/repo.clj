(ns repo "Bounded repository exploration." {:visibility :prompt})

;; Every wrapper speaks the shipped filesystem server's own argument names
;; (`query`, `start_line`, `line_count`) rather than inventing friendlier ones,
;; because a facade that renames a field has to keep that translation correct
;; forever. The one exception is `read-range`, which keeps an inclusive
;; from/to public shape and derives `line_count`: an inclusive range is what a
;; citation quotes, so the caller should not have to compute a count.
;;
;; Collection wrappers take `nil` for the first page and the previous response's
;; `next_cursor` afterwards. A response with no `next_cursor` is the last page.
;; Cursors are opaque and bound to the captured snapshot; nothing here parses or
;; synthesises one.
;;
;; Every data-bearing response carries `snapshot_hash`, which is what binds a
;; cited path and line range to the exact bytes that were queried.

(defn ls
  "Read one directory page. Pass nil first, then the returned next_cursor.

  `path` is a relative prefix; pass \"\" for the repository root. Items carry
  `name`, `kind`, and `path`."
  {:signature "(path :string, cursor :string?) -> :map"}
  [path cursor]
  (cap/unwrap!
    (tool/workspace.list
      (cap/with-cursor {"path" path "limit" 100} cursor))))

(defn find-files
  "Read one page of paths containing a literal substring.

  The server matches a literal substring against each snapshot path; it is not
  a glob. Searching \"agent.core\" finds `priv/preludes/kernel/agent.core.clj`,
  while \"*.clj\" finds nothing."
  {:signature "(query :string, cursor :string?) -> :map"}
  [query cursor]
  (cap/unwrap!
    (tool/workspace.find
      (cap/with-cursor {"query" query "limit" 100} cursor))))

(defn search
  "Read one literal text-search page. Pass nil first, then next_cursor.

  Items carry `path`, `line`, and the matching `text`. A true
  `match_limit_reached` means the server stopped collecting matches, so absence
  of a later match is not evidence."
  {:signature "(query :string, cursor :string?) -> :map"}
  [query cursor]
  (cap/unwrap!
    (tool/workspace.search
      (cap/with-cursor {"query" query "limit" 20} cursor))))

(defn search-under
  "Read one literal text-search page restricted to one relative path prefix."
  {:signature "(query :string, path :string, cursor :string?) -> :map"}
  [query path cursor]
  (cap/unwrap!
    (tool/workspace.search
      (cap/with-cursor {"query" query "path" path "limit" 20} cursor))))

(defn read-range
  "Read inclusive lines `from`..`to` of one relative UTF-8 path.

  Lines carry stable 1-based numbers. `end_of_file` and `truncated` say whether
  the range stopped at the file's end or at the server's line ceiling."
  {:signature "(path :string, from :int, to :int) -> :map"}
  [path from to]
  (if (or (< from 1) (< to from))
    (fail {"error" "invalid-range" "from" from "to" to})
    (cap/unwrap!
      (tool/workspace.read
        {"path" path "start_line" from "line_count" (inc (- to from))}))))
