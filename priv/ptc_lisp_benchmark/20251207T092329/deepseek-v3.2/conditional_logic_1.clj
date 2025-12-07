;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 6279ms

(let [orders ctx/orders]
  (mapv
    (fn [order]
      (let [amount (:amount order)
            size (cond
                   (< amount 100) "small"
                   (<= amount 500) "medium"
                   :else "large")]
        {:id (:id order) :size size}))
    orders))
