;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 1
;; Valid: true
;; Errors: []
;; Duration: 3662ms

(->> ctx/products
     (filter (none-of (where :in_stock = false)))
     (filter (any-of (where :category = "electronics")
                     (where :price > 500))))
