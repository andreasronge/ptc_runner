;; Smoke test: Parallel execution
;; Demonstrates: pmap and pcalls for concurrent execution

;; === Helper functions ===

(defn square [x] (* x x))

(def factor 10)

;; === Parallel operations ===

(let [;; pmap with builtin
      squares (pmap square [1 2 3 4 5])

      ;; pmap with anonymous function and closure
      scaled (pmap #(* % factor) [1 2 3])

      ;; pmap with keyword accessor
      names (pmap :name [{:name "Alice"} {:name "Bob"} {:name "Charlie"}])

      ;; pcalls with multiple thunks
      results (pcalls
               (fn [] (+ 1 1))
               (fn [] (* 2 2))
               (fn [] (square 3)))]

  {:pmap-builtin squares
   :pmap-closure scaled
   :pmap-keyword names
   :pcalls-results results})
