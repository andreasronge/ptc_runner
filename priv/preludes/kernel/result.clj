(ns result "Uniform opt-in workflow result values." {:visibility :prompt})

(defn ok
  "Wraps a successful workflow value in the standard opt-in result envelope."
  [value]
  {:ok true :value value})

(defn error
  "Builds a standard opt-in workflow error envelope."
  [kind reason]
  {:ok false :kind kind :reason reason})

(defn ok?
  "Returns whether a standard result envelope represents success."
  [result]
  (true? (get result :ok)))
