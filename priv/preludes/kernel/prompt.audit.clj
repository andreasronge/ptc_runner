(ns prompt.audit
  "Size measurement for a rendered agent system prompt.

  `agent.prompt/render` interleaves authored instruction text with
  manifest-derived API text, so one byte count for the whole prompt cannot say
  which of the two an edit moved. These functions take the rendered string —
  from a recorded run, a committed fixture, or any other source — and answer
  three questions about it: which segments it is made of, how large each one is,
  and what changed between two versions.

  Every function is pure and takes a string. Nothing here reads a run, calls a
  capability, or assembles a manifest, so the same numbers are available to a
  REPL session reading recorded evidence and to a test guarding a fixture."
  {:visibility :discoverable})

(defn- occurs-once? [text needle]
  (let [first-at (index-of text needle)]
    (and (not (nil? first-at))
         (nil? (index-of text needle (inc first-at))))))

(defn- unrecognised [text]
  [{"label" "unrecognised" "text" text}])

;; The last blank line strictly before the legend, never the first one after the
;; heading. A namespace docstring may contain a blank line, and ending the notes
;; at the first would cut manifest text off inside its own segment and count the
;; remainder as authored — the one way a reporting row can lie about provenance
;; rather than merely approximate it.
(defn- notes-terminator [text from legend-at]
  (let [at (last-index-of text "\n\n" (- legend-at 2))]
    (if (and (not (nil? at)) (> at from))
      (+ at 2)
      nil)))

;; Recognition fails closed. Manifest text reaches the prompt unescaped, so a
;; namespace docstring can reproduce an anchor; when that makes an anchor occur
;; twice the provenance of every boundary after it is unknowable from the string
;; alone, and guessing would report authored characters that a manifest wrote.
(defn- api-segments [text head api-end api-limit tail]
  (let [legend "In map types, field? means the field may be omitted; type? means nil is allowed.\n\n"
        empty-api "- No mission-specific data, functions, or tools are available.\n"
        notes-anchor "API notes\n"
        notes-start (+ api-end (count notes-anchor))
        notes? (= notes-anchor (subs text api-end notes-start))]
    (if (= empty-api (subs text api-end api-limit))
      (into (into head [{"label" "api-empty" "text" empty-api}]) tail)
      (if (and (occurs-once? text legend)
             (or (not notes?) (occurs-once? text notes-anchor)))
      (let [legend-at (index-of text legend)
            legend-end (+ legend-at (count legend))
            entries (subs text legend-end api-limit)
            notes-end (if notes? (notes-terminator text notes-start legend-at) api-end)]
        ;; Every rendered entry ends in a newline and render-api appends one
        ;; more, so a complete entry list ends in a blank line. Requiring only a
        ;; single newline would accept a rendering truncated by one character
        ;; and measure a partial prompt as a whole one.
        (if (and (not (nil? notes-end))
                 (>= legend-at notes-end)
                 (ends-with? entries "\n\n"))
          (into (into (into head
                            (if (= notes-end api-end)
                              []
                              [{"label" "api-notes" "text" (subs text api-end notes-end)}]))
                      [{"label" "api-legend" "text" (subs text notes-end legend-end)}
                       {"label" "api-entries" "text" entries}])
                tail)
          (unrecognised text)))
        (unrecognised text)))))

(defn- contract-tail [text api-end]
  (let [result-anchor "\nApplication result contract\n"
        phase-anchor "\nCurrent phase return contract ("
        result-at (index-of text result-anchor api-end)
        phase-at (index-of text phase-anchor api-end)
        unique? (and (or (nil? result-at) (occurs-once? text result-anchor))
                     (or (nil? phase-at) (occurs-once? text phase-anchor)))
        ordered? (or (nil? result-at) (nil? phase-at) (< result-at phase-at))
        api-limit (or result-at phase-at (count text))
        result-text (when (not (nil? result-at))
                      (subs text result-at (or phase-at (count text))))
        phase-text (when (not (nil? phase-at)) (subs text phase-at))
        result-valid? (or (nil? result-text)
                          (and (or (starts-with? result-text
                                                 "\nApplication result contract\nThe host validates the exact value passed to (return value).\nType: ")
                                   (starts-with? result-text
                                                 "\nApplication result contract\nThe host validates {\"ok\":true,\"value\":value}. Return only value; do not construct or return that envelope yourself.\nType: "))
                               (ends-with? result-text "\n")))
        phase-valid? (or (nil? phase-text)
                         (and (index-of phase-text ")\nA valid explicit (return value) is required to transition to the next phase.\nType: ")
                              (ends-with? phase-text "\n")))]
    (if (and unique? ordered? result-valid? phase-valid?)
      {"api-limit" api-limit
       "tail" (into (if (nil? result-at)
                       []
                       [{"label" "result-contract"
                         "text" (subs text result-at (or phase-at (count text)))}])
                     (if (nil? phase-at)
                       []
                       [{"label" "phase-return-contract"
                         "text" (subs text phase-at)}]))}
      nil)))

(defn segments
  "Splits a rendered agent system prompt into its ordered emission segments.

  Returns a vector of {\"label\" .. \"text\" ..} in the order `render` emits
  them: marker, protocol, language, examples, api-heading, api-notes,
  api-legend, api-entries, result-contract, phase-return-contract. Each label
  occurs at most once. `api-notes`, `api-entries`, and both optional contract
  projections are manifest-derived; the remaining segments are authored in
  `agent.prompt`. The order is the structure — the rendering interleaves
  authored and dynamic text, so no unordered value can encode reassembly.

  The authored empty-API sentence is an `api-empty` segment. `api-notes` is absent
  when the mission declares no namespace docstrings. Result and phase-return
  contracts are optional dynamic suffix segments.

  Any string that is not a shipped rendering — a manifest's own prompt, a
  malformed one, or one whose manifest text reproduces an anchor — returns a
  single `unrecognised` segment carrying the whole input.

  Joining the segment texts in order reproduces the input exactly, in both the
  recognised and the unrecognised case. That invariant is what makes the
  per-segment character counts add up to the whole."
  [text]
  (let [marker "PTC_AGENT_PROMPT_V1\n\n"
        protocol-anchor "Instructions\n"
        language-anchor "PTC-Lisp\n"
        examples-anchor "Examples\n"
        api-anchor "Available API\n"]
    (if (and (string? text)
             (starts-with? text marker)
             (occurs-once? text protocol-anchor)
             (occurs-once? text language-anchor)
             (occurs-once? text examples-anchor)
             (occurs-once? text api-anchor))
      (let [protocol-at (index-of text protocol-anchor)
            language-at (index-of text language-anchor)
            examples-at (index-of text examples-anchor)
            api-at (index-of text api-anchor)
            api-end (+ api-at (count api-anchor))]
        (if (and (= (count marker) protocol-at)
                 (< protocol-at language-at)
                 (< language-at examples-at)
                 (< examples-at api-at))
          (let [head [{"label" "marker" "text" (subs text 0 (count marker))}
                      {"label" "protocol" "text" (subs text protocol-at language-at)}
                      {"label" "language" "text" (subs text language-at examples-at)}
                      {"label" "examples" "text" (subs text examples-at api-at)}
                      {"label" "api-heading" "text" (subs text api-at api-end)}]
                contracts (contract-tail text api-end)]
            (if (nil? contracts)
              (unrecognised text)
              (api-segments text head api-end
                            (get contracts "api-limit")
                            (get contracts "tail"))))
          (unrecognised text)))
      (unrecognised text))))


;; Neither loop/recur, a regex, nor `(seq text)`. Evaluation caps loops at a
;; thousand iterations, the regex runtime truncates at 32,768 bytes, and seq
;; materialises every grapheme as a heap-heavy list. String replacement keeps
;; the large payload in binaries while the difference gives the exact count.
(defn- newline-count [text]
  (- (count text) (count (replace text "\n" ""))))

(defn- text-characters [text]
  (if (string? text) (count text) 0))

;; A trailing newline closes its line rather than opening an empty one, so a
;; segment that ends in "\n" counts exactly its breaks. Summing segment lines
;; therefore reproduces the whole-string count for any rendering in which only
;; the last segment may lack one.
(defn- text-lines [text]
  (if (string? text)
    (let [breaks (newline-count text)]
      (if (or (= "" text) (ends-with? text "\n"))
        breaks
        (inc breaks)))
    0))

(defn- row [label characters lines]
  {"label" label
   "characters" characters
   "lines" lines
   "tokens_estimated" (ceil (/ characters 4))})

(defn- segment-row [segment]
  (let [text (get segment "text")]
    (row (get segment "label") (text-characters text) (text-lines text))))

(defn- authored-row? [row]
  (let [label (get row "label")]
    (not (or (= "api-notes" label)
             (= "api-entries" label)
             (= "result-contract" label)
             (= "phase-return-contract" label)))))

(defn- derived-row [label rows]
  (row label
       (reduce + 0 (map #(get % "characters") rows))
       (reduce + 0 (map #(get % "lines") rows))))

(defn measure
  "Measures a rendered agent system prompt, per segment and in total.

  Returns {\"rows\" [...] \"recognised?\" bool}. `rows` holds one row per
  present segment in emission order, then the derived rows `authored`,
  `dynamic` and `total`. Each row is {\"label\" .. \"characters\" ..
  \"lines\" .. \"tokens_estimated\" ..}.

  `characters` is authoritative and counts graphemes, as `count` does. Bytes
  are not reported: the string surface exposes no UTF-8 byte size, and
  characters are tokenizer-independent and sufficient for a budget.
  `tokens_estimated` is ceil(characters / 4) — an estimate, named so a caller
  cannot mistake it for a measurement — and the derived rows compute it from
  their own aggregated character count rather than by summing per-segment
  estimates, which would differ.

  `authored` sums the fixed prompt-policy segments. `dynamic` sums `api-notes`,
  `api-entries`, and the manifest-driven result and phase contract projections;
  an `unrecognised` segment counts as authored. So
  authored + dynamic equals total in both cases. Treat the split as approximate
  reporting: the dynamic segments carry authored formatter text — headings and
  the per-entry `Call`, `Type` and `Docs` labels — so it
  says roughly how much of a rendering a manifest drove, and no more. A budget
  reads `total`."
  [text]
  (let [parts (segments text)
        rows (mapv segment-row parts)
        whole (if (string? text) text "")]
    {"rows" (into rows
                  [(derived-row "authored" (filterv authored-row? rows))
                   (derived-row "dynamic" (filterv #(not (authored-row? %)) rows))
                   (row "total" (text-characters whole) (text-lines whole))])
     "recognised?" (not= "unrecognised" (get (first parts) "label"))}))

(defn- characters-for [rows label]
  (let [found (first (filterv #(= label (get % "label")) rows))]
    (if (nil? found) 0 (get found "characters"))))

(defn- percent-change [before change]
  (if (= 0 before)
    nil
    (/ (round (* 1000.0 (/ change before))) 10.0)))

(defn- delta-row [before-rows after-rows label]
  (let [before (characters-for before-rows label)
        after (characters-for after-rows label)
        change (- after before)]
    {"label" label
     "before" before
     "after" after
     "change" change
     "percent" (percent-change before change)}))

(defn delta
  "Compares two rendered prompts and reports the character change per segment.

  Returns {\"rows\" [...]}, one row per label present in either input, in the
  emission order of `after` with labels unique to `before` appended. Each row is
  {\"label\" .. \"before\" .. \"after\" .. \"change\" .. \"percent\" ..}.

  All three counts are characters; `delta` reports no token estimates. A label
  present on only one side counts 0 on the other. `percent` is the change
  against `before` rounded to one decimal place, and nil when `before` is 0."
  [before after]
  (let [before-rows (get (measure before) "rows")
        after-rows (get (measure after) "rows")
        after-labels (mapv #(get % "label") after-rows)
        only-before (filterv #(not (some (fn [label] (= label %)) after-labels))
                             (mapv #(get % "label") before-rows))]
    {"rows" (mapv #(delta-row before-rows after-rows %) (into after-labels only-before))}))
