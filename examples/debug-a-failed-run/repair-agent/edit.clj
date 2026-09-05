(ns repair.edit "Propose exact edits to captured source; metadata and unchanged bytes come from evidence." {:visibility :prompt})

(defn- apply-edits [source edits]
  (loop [text source pending edits]
    (if (empty? pending)
      {"source" text}
      (let [edit (first pending) before (get edit "before") after (get edit "after")]
        (cond
          (or (not (string? before)) (blank? before) (not (string? after)) (= before after))
          {"edit_error" "Each edit needs distinct before/after strings and a nonblank before string."}
          :else
          (let [position (index-of text before)]
            (cond
              (nil? position) {"edit_error" "The before text does not occur in the captured source."}
              (some? (index-of text before (inc position)))
              {"edit_error" "The before text occurs more than once; supply a larger unique fragment."}
              :else
              (recur (str (subs text 0 position) after (subs text (+ position (count before)))) (rest pending)))))))))

(defn propose
  "Build a complete repair report from one frozen component and exact text edits. Target has component_id, environment, function_id, and mission_name for a mission component. Edits is a nonempty vector of maps with before and after strings; every before fragment must match exactly once. Copies source identity and hash from the capture, preserves all unedited bytes, and returns through repair.terminal/propose. A refused edit returns edit_error so you can correct it. Never provide a source hash or whole replacement file."
  {:signature "(run-id :string, target :map, edits [:map], cause :string, evidence [:string]) -> :map"}
  [run-id target edits cause evidence]
  (if (empty? edits)
    {"edit_error" "At least one edit is required."}
    (let [page (debug.nav/read run-id (assoc (select-keys target ["component_id" "environment" "mission_name"]) "collection" "prelude_sources" "limit" 2))
          items (get page "items")]
      (if (or (not= 1 (count items)) (get page "truncated") (get page "next_cursor"))
        {"edit_error" "Target must identify exactly one complete frozen source."}
        (let [item (first items) changed (apply-edits (get item "source") edits)]
          (if (get changed "edit_error") changed
            (repair.terminal/propose
              {"run_id" run-id "cause" cause "evidence" evidence
               "component_id" (get item "component_id")
               "function_id" (get target "function_id")
               "target_environment" (get item "environment")
               "target_mission" (get item "mission_name")
               "base_source_hash" (get item "source_hash")
               "candidate_source" (get changed "source")})))))))
