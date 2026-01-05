;; Smoke test: Higher-order functions and closures
;; Demonstrates: fn, closures, group-by, filter predicates

(let [;; Create a reusable transformer factory (closure)
      make-processor (fn [multiplier offset]
                       (fn [x] (+ (* x multiplier) offset)))

      ;; Instantiate processors
      double-plus-one (make-processor 2 1)
      triple-minus-two (make-processor 3 -2)

      ;; Compose manually via lambda
      combined (fn [x] (triple-minus-two (double-plus-one x)))

      ;; Apply to data
      numbers [1 2 3 4 5]
      processed (map combined numbers)

      ;; Group using group-by
      grouped (group-by odd? numbers)

      ;; Closure for adding
      add-ten (fn [x] (+ 10 x))
      with-bonus (map add-ten processed)

      ;; Filter with predicate closure
      threshold 20
      above-threshold (fn [x] (> x threshold))
      high-values (filter above-threshold with-bonus)]

  {:processed processed
   :grouped grouped
   :with-bonus with-bonus
   :high-values high-values
   :sum (reduce + 0 with-bonus)})
