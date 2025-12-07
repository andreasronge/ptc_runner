;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 5523ms

(map
 (fn [{:keys [id amount]}]
   (let [size (cond
                (< amount 100) "small"
                (>= amount 500) "large"
                :else "medium")]
     {:id id :size size}))
 ctx/orders)
