(ns gateway.example)

(defn run {:effect :read} [input]
  (return {"value" (str (kernel/mission-inventory "default"))}))
