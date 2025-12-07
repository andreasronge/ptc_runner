;; Scenario: predicate_combinator
;; Level: 3
;; Iteration: 3
;; Valid: true
;; Errors: []
;; Duration: 3305ms

(filter
  (all-of
    (any-of
      (where :category = "electronics")
      (where :price > 500))
    (where :in_stock))
  ctx/products)
