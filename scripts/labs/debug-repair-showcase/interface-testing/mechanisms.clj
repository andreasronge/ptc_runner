;; Run through the private analysis profile for one comparison project.
;; These textual counters are clues, not proof that an action was warranted.
(mapv
  (fn [row]
    (let [id (get row "run_id")
          page (analysis/read id {"collection" "turns" "limit" 30})
          turns (get page "items")
          programs (mapcat #(get % "generated") turns)
          feedback (mapcat #(get % "feedback") turns)
          first-request (pr-str (first turns))]
      {"run_id" id
       "complete_turn_page" (and (not (get page "truncated")) (nil? (get page "next_cursor")))
       "new_read_doc_visible" (includes? first-request "Obtain identifiers from returned records")
       "new_follow_doc_visible" (includes? first-request "returns navigation_error with page nil")
       "programs_mentioning_example_id"
       (count (filter #(includes? (get % "source" "") "mission-evaluation-9") programs))
       "feedback_with_recovery_error"
       (count (filter #(includes? (get % "content" "") "relationship_unavailable") feedback))
       "programs_with_follow"
       (count (filter #(includes? (get % "source" "") "debug.nav/follow") programs))}))
  (get (analysis/runs {"limit" 10}) "items"))
