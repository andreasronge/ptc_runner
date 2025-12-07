;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 2
;; Valid: true
;; Errors: []
;; Duration: 2211ms

(filter
  (all-of
    (any-of
      (where :category = "electronics")
      (where :price > 500))
    (where :in_stock))
  ctx/products)
