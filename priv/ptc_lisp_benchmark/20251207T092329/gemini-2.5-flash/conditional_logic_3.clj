;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 1601ms

(mapv
  (fn [order]
    (assoc order
      :size
      (cond
        (< (:amount order) 100) :small
        (<= (:amount order) 500) :medium
        :else :large)))
  ctx/orders)
