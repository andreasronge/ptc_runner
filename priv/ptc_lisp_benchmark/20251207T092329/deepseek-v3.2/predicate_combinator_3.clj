;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 3023ms

(let [products ctx/products]
  (filter (all-of 
            (any-of (where :category = "electronics") 
                    (where :price > 500))
            (where :in_stock = true))
          products))
