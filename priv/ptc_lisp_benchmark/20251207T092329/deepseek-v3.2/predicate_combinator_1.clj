;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 5207ms

(let [products ctx/products]
  (->> products
       (filter (all-of
                 (any-of
                   (where :category = "electronics")
                   (where :price > 500))
                 (where :in_stock true)))))
