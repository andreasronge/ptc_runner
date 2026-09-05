(ns main "Check focused evidence fidelity without a model." {:visibility :prompt})

(defn run
  "Compare focused pages with the original captured source and relationships."
  {:signature "(input :map) -> :map"}
  [input]
  (let [evaluation
        (kernel/eval-with "evidence"
          (program
            (let [run-id (get data/params "run_id")
                  options {"collection" "generated_sources" "limit" 10}
                  raw (debug.nav/read run-id options)
                  focused (debug.view/read run-id options)
                  source-keys ["source" "source_hash" "relationships" "evaluation_id"
                               "parent_evaluation_id" "environment" "mission_name"]
                  relationship (first (filter #(= "complete" (get % "state"))
                                        (mapcat #(get % "relationships") (get raw "items"))))
                  raw-follow (debug.nav/follow run-id relationship {})
                  focused-follow (debug.view/follow run-id relationship {})
                  exact? (= (mapv #(select-keys % source-keys) (get raw "items"))
                            (mapv #(select-keys % source-keys) (get focused "items")))
                  exact-follow? (= (mapv #(select-keys % source-keys) (get-in raw-follow ["page" "items"]))
                                   (mapv #(select-keys % source-keys) (get-in focused-follow ["page" "items"])))
                  metadata? (= (dissoc raw "items") (dissoc focused "items"))
                  follow-metadata? (= (update raw-follow "page" #(dissoc % "items"))
                                      (update focused-follow "page" #(dissoc % "items")))]
              (if (and exact? exact-follow? metadata? follow-metadata?)
                (return {"exact_source_and_links" true "exact_page_metadata" true
                         "native_chars" (count (pr-str raw))
                         "focused_chars" (count (pr-str focused))})
                (fail "focused source evidence changed"))))
          input)]
    (if (= :returned (get evaluation :outcome))
      (return (get evaluation :value))
      (fail "focused evidence probe failed"))))
