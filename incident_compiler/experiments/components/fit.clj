(ns fit
  "Model-judged applicability of a documented export.

  Answers one question: will the export named by `ref` handle this task, on
  data shaped like this sample? The export's own documentation is read through
  `export-meta`, so the judgement is made against the doc that ships rather
  than a copy maintained by hand."
  {:visibility :prompt
   ;; Generic concerns, not tied to any application: whichever of these the
   ;; model thinks blocks the fit is recorded as a counter, so a canonical
   ;; trace carries WHY a judgement went the way it did without carrying the
   ;; model's prose. The sentence itself is returned to the caller and kept in
   ;; the private inspection record.
   :annotations {"fit-verdict" ["fits" "scale" "shape" "capability" "iteration"]}})

(def concerns ["scale" "shape" "capability" "iteration"])

(defn- verdict-of [content]
  ;; Pessimistic: only an explicit affirmative counts. A hedged answer, a
  ;; malformed one, or a provider error all mean false, because the caller
  ;; uses this to decide whether to skip a slower path that is known to work.
  (and (string? content)
       (includes? (str/lower-case (str content)) "verdict: yes")))

(defn- reason-of [content]
  ;; `split` takes a regex or char, not a string, so the reason is a bounded
  ;; prefix of the whole reply rather than the part above the CONCERNS line.
  (let [head (str/trim (str content))]
    (subs head 0 (min 300 (count head)))))

(defn- flags-of [content]
  ;; Matched against the whole reply. A concern named only in the reasoning
  ;; sentence still flags, which over-reports rather than under-reports — the
  ;; conservative direction for a signal used to avoid skipping a slow path.
  (let [text (str/lower-case (str content))]
    (reduce (fn [acc c] (assoc acc c (if (includes? text c) 1 0))) {} concerns)))

(defn handles?
  "Ask the model whether `ref` handles `task` on data shaped like `sample`.

  Returns `{verdict, reason, concerns}`. `verdict` is false when `ref` names no
  export, when the model gives no explicit affirmative, or on a provider error.
  `concerns` flags which generic obstacle the model raised: `scale` (too much
  data), `shape` (data does not match the declared inputs), `capability` (the
  function does not do what the task needs), `iteration` (the task needs
  passes the function does not make). The sample is summarised with `describe`,
  so shape and key coverage are sent rather than the data itself."
  {:signature "(ref :string, task :string, sample :any) -> {verdict :bool, reason :string, concerns :map}"
   :effect :read}
  [ref task sample]
  (let [meta (export-meta ref)]
    (if (nil? meta)
      {"verdict" false "reason" "no such export" "concerns" (flags-of "")}
      (let [response (llm/request
                       {"system" (str "You judge whether a documented function fits a task. "
                                      "Reply in exactly three parts: one sentence of reasoning; "
                                      "then a line `CONCERNS: ` listing any of "
                                      "scale, shape, capability, iteration that block the fit, "
                                      "or none; then a line reading exactly VERDICT: yes or "
                                      "VERDICT: no. Be conservative: answer yes only if the "
                                      "documentation shows the function handles this task on "
                                      "data of this shape.")
                        "messages"
                        [{"role" "user"
                          "content" (str "Function: " (get meta "call") "\n"
                                         "Signature: " (or (get meta "signature") "not declared") "\n"
                                         "Effect: " (get meta "effect") "\n"
                                         "Documentation:\n" (get meta "doc") "\n\n"
                                         "Task:\n" task "\n\n"
                                         "Shape of the data this function will operate on. It fetches this\n"
                                         "itself from its own source; it is not passed in as an argument:\n"
                                         (str (describe sample)) "\n\n"
                                         "Will this function handle that task on that data?")}]})
            content (get response "content")
            verdict (verdict-of content)
            flags (flags-of content)]
        (workflow.event/annotate "fit-verdict" (assoc flags "fits" (if verdict 1 0)))
        {"verdict" verdict "reason" (reason-of content) "concerns" flags}))))
