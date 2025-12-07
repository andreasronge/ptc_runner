;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 3578ms

(mapv
  (fn [order]
    (assoc (select-keys order [:id])
           :size
           (cond
             (< (:amount order) 100) :small
             (<= 100 (:amount order) 500) :medium
             :else :large)))
  ctx/orders)
