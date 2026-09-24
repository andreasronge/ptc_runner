(ns lab.boundary
  "Credential-free boundary probe for the raw ptc-web wrapper."
  {:visibility :prompt})

(defn- returned-value [outcome]
  (if (= :returned (get outcome :outcome)) (get outcome :value) (fail outcome)))

(defn run [input]
  (return
    (returned-value
      (kernel/eval-with
        "default"
        (program
          (let [handle (lab.web/open (get data/params "url"))
                snapshot (lab.web/capture (get handle "handle_id"))
                first-page (lab.web/extract
                             (get snapshot "snapshot_id")
                             "article.entry"
                             [{"name" "markup" "source" "html"}]
                             1
                             nil)
                second-page (lab.web/extract
                              (get snapshot "snapshot_id")
                              "article.entry"
                              [{"name" "markup" "source" "html"}]
                              1
                              (get first-page "next_cursor"))]
            (lab.web/close (get handle "handle_id"))
            (return {"first" (get-in first-page ["records" 0 "markup"])
                     "second" (get-in second-page ["records" 0 "markup"])
                     "first_next_cursor" (get first-page "next_cursor")
                     "second_next_cursor" (get second-page "next_cursor")})))
        {"url" (get input "url")}))))
