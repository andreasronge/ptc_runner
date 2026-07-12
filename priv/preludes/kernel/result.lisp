(ns result "Uniform opt-in workflow result values." {:visibility :prompt})

(defn ok [value] {:ok true :value value})
(defn error [kind reason] {:ok false :kind kind :reason reason})
(defn ok? [result] (true? (get result :ok)))
