;; Smoke test: Definitions and sequential evaluation
;; Demonstrates: def, defn, multiple expressions, persistence
;; Note: Only the LAST expression's result is compared

;; === def basics ===
(def counter 0)
(def threshold 100)
(def multiplier 2.5)
(def scaled-threshold (* threshold multiplier))

;; Chain of defs
(def a 1)
(def b (+ a 1))
(def c (+ b 1))

;; === defn basics ===
(defn twice [x] (* x 2))
(defn add [a b] (+ a b))
(defn quadruple [x] (twice (twice x)))

(defn distance [x1 y1 x2 y2]
  (let [dx (- x2 x1)
        dy (- y2 y1)]
    (+ (* dx dx) (* dy dy))))

;; === defn with implicit do (multiple body expressions) ===
(def call-log [])

(defn tracked-twice [x]
  (def call-log (conj call-log x))
  (* x 2))

(tracked-twice 1)
(tracked-twice 2)
(tracked-twice 3)

;; === defn referencing other defs ===
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

;; === Higher-order functions ===
(defn make-adder [n]
  (fn [x] (+ x n)))

(defn make-multiplier [n]
  (fn [x] (* x n)))

(def add-10 (make-adder 10))
(def times-3 (make-multiplier 3))

(defn compose [f g]
  (fn [x] (f (g x))))

(def add-then-multiply (compose times-3 add-10))

;; === Data processing ===
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

;; === Final result (this is what gets compared) ===
{:counter counter
 :threshold threshold
 :scaled-threshold scaled-threshold
 :chain [a b c]
 :twice-5 (twice 5)
 :add-3-4 (add 3 4)
 :quadruple-3 (quadruple 3)
 :distance (distance 0 0 3 4)
 :tracked-results [(tracked-twice 10) (tracked-twice 20)]
 :call-log call-log
 :tax-50 (calculate-total 50)
 :tax-150 (calculate-total 150)
 :add-10-of-5 (add-10 5)
 :times-3-of-4 (times-3 4)
 :composed-5 (add-then-multiply 5)
 :processed processed
 :total total
 :avg avg}
