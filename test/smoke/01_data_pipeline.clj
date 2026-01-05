;; Smoke test: Data transformation pipeline
;; Demonstrates: map, filter, reduce, threading, let, fn

(let [items [{:name "apple" :price 1.50 :qty 3}
             {:name "banana" :price 0.75 :qty 5}
             {:name "cherry" :price 3.00 :qty 2}
             {:name "date" :price 2.25 :qty 4}]

      ;; Calculate line totals
      with-totals (map (fn [item]
                         (assoc item :total (* (:price item) (:qty item))))
                       items)

      ;; Filter expensive items (total > 5)
      expensive (->> with-totals
                     (filter (fn [item] (> (:total item) 5))))

      ;; Sum all totals
      grand-total (reduce + 0 (map :total with-totals))]

  {:item-count (count items)
   :expensive-count (count expensive)
   :expensive-names (map :name expensive)
   :grand-total grand-total})
