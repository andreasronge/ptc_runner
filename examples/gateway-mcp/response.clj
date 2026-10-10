(ns response "Check capability responses." {:visibility :discoverable})

(defn value {:effect :read} [result]
  (if (= :ok (get result :status)) (get result :value) (fail result)))
