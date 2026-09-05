(ns self.check "Check a proposed navigation helper against a frozen application capture." {:visibility :prompt})

(defn run
  "Verify that the helper follows a complete source relationship without inventing its page."
  {:signature "(input :map) -> :map"}
  [_input]
  (let [result (kernel/eval "evidence"
                 (program
                   (let [context (debug.start/context)
                         run-id (get context "run_id")
                         generated (get context "generated")
                         relationships (filter #(and (= "complete" (get % "state"))
                                                      (= "referenced_prelude_source" (get % "rel")))
                                               (get generated "relationships"))
                         pages (mapv #(get (debug.nav/follow run-id % {}) "page") relationships)]
                     (return {"valid_source" (boolean (some #(= % (get context "source")) pages))
                              "source_count" (count (get-in context ["source" "items"]))
                              "run_id" run-id}))))]
    (if (and (= :returned (get result :outcome))
             (true? (get-in result [:value "valid_source"]))
             (pos? (get-in result [:value "source_count"])))
      (return (get result :value))
      (fail {"stage" "helper-validation" "outcome" result}))))
