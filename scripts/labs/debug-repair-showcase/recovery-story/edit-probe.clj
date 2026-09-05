(ns main "Boundary checks for exact source-edit proposals." {:visibility :prompt})
(defn run "Check refusal paths and captured metadata preservation." [input]
  (let [checks (kernel/eval-with "synthesize"
                 (program
                   (let [id (get data/params "run_id") target (get data/params "target")
                         no-match (repair.edit/propose id target [{"before" "NOT IN SOURCE" "after" "replacement"}] "check" ["check"])
                         multiple (repair.edit/propose id target [{"before" "Return the exclusive end page unchanged" "after" "replacement"}] "check" ["check"])
                         no-op (repair.edit/propose id target [{"before" "text" "after" "text"}] "check" ["check"])]
                     (return {"missing_refused" (string? (get no-match "edit_error"))
                              "multiple_refused" (string? (get multiple "edit_error"))
                              "no_op_refused" (string? (get no-op "edit_error"))}))) input)
        original (kernel/eval-with "synthesize"
                   (program (return (first (get (debug.nav/read (get data/params "run_id") {"collection" "prelude_sources" "component_id" "page.stop" "environment" "mission" "mission_name" "pages"}) "items")))) input)
        proposal (kernel/eval-with "synthesize"
                   (program (repair.edit/propose (get data/params "run_id") (get data/params "target")
                              [{"before" "(inc (get request \"end\"))" "after" "(get request \"end\")"}]
                              "boundary check" ["frozen source"])) input)
        v (get proposal :value) source (get original :value)]
    (if (and (= :returned (get checks :outcome))
             (every? true? (vals (get checks :value)))
             (= :returned (get proposal :outcome))
             (= (get source "source_hash") (get v "base_source_hash"))
             (= (replace (get source "source") "(inc (get request \"end\"))" "(get request \"end\")") (get v "candidate_source")))
      (return (assoc (get checks :value) "exact_hash" true "unchanged_bytes_preserved" true))
      (fail "edit proposal checks failed"))))
