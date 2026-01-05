;; Smoke test: Definitions and sequential evaluation
;; Demonstrates: def, defn, do, multiple expressions, persistence patterns

;; === Part 1: Basic def ===

;; def returns a var, not the value
(do
  (def counter 0)
  (def threshold 100)
  (def multiplier 2.5)

  ;; Can reference previous defs
  (def scaled-threshold (* threshold multiplier))

  ;; Chain of defs
  (def a 1)
  (def b (+ a 1))
  (def c (+ b 1))

  {:counter counter
   :threshold threshold
   :scaled-threshold scaled-threshold
   :chain [a b c]})

;; === Part 2: defn basics ===

(do
  ;; Simple function
  (defn double [x] (* x 2))

  ;; Function with multiple params
  (defn add [a b] (+ a b))

  ;; Function calling another function
  (defn quadruple [x] (double (double x)))

  ;; Function with expression body
  (defn distance [x1 y1 x2 y2]
    (let [dx (- x2 x1)
          dy (- y2 y1)]
      (+ (* dx dx) (* dy dy))))  ; squared distance

  {:double-5 (double 5)
   :add-3-4 (add 3 4)
   :quadruple-3 (quadruple 3)
   :distance (distance 0 0 3 4)})

;; === Part 3: defn with implicit do ===

(do
  ;; defn body can have multiple expressions
  (def call-log [])

  (defn tracked-double [x]
    (def call-log (conj call-log x))  ; side effect
    (* x 2))                           ; return value

  ;; Call multiple times
  (tracked-double 1)
  (tracked-double 2)
  (tracked-double 3)

  {:results [(tracked-double 10) (tracked-double 20)]
   :log call-log})

;; === Part 4: defn referencing ctx and other defs ===

(do
  (def tax-rate 0.08)
  (def discount-threshold 100)

  (defn apply-tax [amount]
    (* amount (+ 1 tax-rate)))

  (defn apply-discount [amount]
    (if (> amount discount-threshold)
      (* amount 0.9)
      amount))

  (defn calculate-total [subtotal]
    (-> subtotal
        apply-discount
        apply-tax))

  {:raw-50 (calculate-total 50)
   :raw-150 (calculate-total 150)})

;; === Part 5: do with mixed expressions ===

(do
  ;; do evaluates all, returns last
  (def step1 "init")
  (def step2 "process")
  (def step3 "complete")

  ;; Nested do blocks
  (do
    (def outer "outer")
    (do
      (def inner "inner")
      {:outer outer :inner inner})))

;; === Part 6: defn as higher-order functions ===

(do
  (defn make-adder [n]
    (fn [x] (+ x n)))

  (defn make-multiplier [n]
    (fn [x] (* x n)))

  (def add-10 (make-adder 10))
  (def times-3 (make-multiplier 3))

  (defn compose [f g]
    (fn [x] (f (g x))))

  (def add-then-multiply (compose times-3 add-10))

  {:add-10-of-5 (add-10 5)
   :times-3-of-4 (times-3 4)
   :composed-5 (add-then-multiply 5)})

;; === Part 7: Complex multi-expression flow ===

(do
  ;; Simulate a data processing pipeline with state
  (def items [{:id 1 :value 100}
              {:id 2 :value 200}
              {:id 3 :value 50}])

  (defn process-item [item]
    {:id (:id item)
     :original (:value item)
     :processed (* (:value item) 1.1)})

  (def processed (map process-item items))
  (def total (reduce + (map :processed processed)))
  (def avg (/ total (count processed)))

  {:processed processed
   :total total
   :avg avg})
