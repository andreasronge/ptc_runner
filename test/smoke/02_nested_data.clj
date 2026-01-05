;; Smoke test: Nested data manipulation
;; Demonstrates: get-in, assoc-in, update, merge, destructuring

(let [user {:id 1
            :profile {:name "Alice"
                      :settings {:theme "dark"
                                 :notifications true}}
            :scores [85 92 78 95]}

      ;; Deep access
      theme (get-in user [:profile :settings :theme])

      ;; Deep update using assoc-in
      updated (-> user
                  (assoc-in [:profile :settings :theme] "light")
                  (assoc-in [:profile :settings :language] "en"))

      ;; Destructure and compute
      {:keys [scores]} user
      total (reduce + scores)
      avg (/ total (count scores) 1.0)

      ;; Merge data
      extra {:verified true :level 5}
      enriched (merge (select-keys user [:id]) extra)]

  {:original-theme theme
   :new-theme (get-in updated [:profile :settings :theme])
   :has-language (contains? (get-in updated [:profile :settings]) :language)
   :score-avg avg
   :enriched enriched})
