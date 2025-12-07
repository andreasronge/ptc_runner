;; Scenario: conditional_logic
;; Level: 3
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 4261ms

(mapv
  (fn [order]
    (let [amount (:amount order)]
      {:id (:id order)
       :size (cond
               (< amount 100) :small
               (<= 100 amount 500) :medium
               (> amount 500) :large
               :else nil)}))
  ctx/input)
