(ns tutorial.signatures "Small signed mission functions." {:visibility :prompt})

(defn double
  "Double one integer."
  {:signature "(value :int) -> :int"}
  [value]
  (* value 2))
