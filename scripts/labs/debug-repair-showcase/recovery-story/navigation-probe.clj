(ns main "Check unavailable-link recovery and exact successful evidence." {:visibility :prompt})

(defn run "Require recovery without changing successful navigation or option guards." {:signature "(input :map) -> :map"} [input]
  (let [check (kernel/eval-with "evidence"
                (program
                  (let [run-id (get data/params "run_id")
                        page (debug.nav/read run-id {"collection" "generated_sources"})
                        links (mapcat #(get % "relationships") (get page "items"))
                        unavailable (first (filter #(= "unavailable" (get % "state")) links))
                        available (first (filter #(and (= "complete" (get % "state")) (= "prelude_sources" (get % "target_collection"))) links))
                        refusal (debug.nav/follow run-id unavailable {})
                        followed (debug.nav/follow run-id available {})
                        raw (debug.nav/read run-id (assoc (get available "filters") "collection" (get available "target_collection")))]
                    (if (and unavailable available
                             (and (false? (get refusal "ok")) (string? (get refusal "reason")))
                             (nil? (get refusal "page"))
                             (= unavailable (get refusal "relationship"))
                             (= available (get followed "relationship"))
                             (= raw (get followed "page"))
                             (seq (get raw "items")))
                      (return {"recovered" true "exact_valid_page" true "unavailable_page" nil})
                      (fail "recovery or evidence fidelity check failed")))) input)]
    (if (= :returned (get check :outcome))
      (let [guard (kernel/eval-with "evidence"
                    (program (debug.nav/follow (get data/params "run_id") {} {"collection" "prelude_sources"})) input)]
        (if (= :failed (get guard :outcome))
          (return (assoc (get check :value) "invalid_options_still_rejected" true))
          (fail "invalid follow options were accepted")))
      (fail "unavailable-link recovery did not complete"))))
