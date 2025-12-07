;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 15725ms

(let [orders ctx/orders]
  (mapv (fn [order]
          (let [amount (:amount order)
                size (cond
                      (< amount 100) "small"
                      (<= amount 500) "medium"
                      :else "large")]
            {:id (:id order)
             :size size}))
        orders))
