;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 3090ms

(filter (all-of
         (any-of (where :category = "electronics")
                 (where :price > 500))
         (none-of (where :in_stock = false)))
        ctx/products)
