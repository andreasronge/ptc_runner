(ns inspection "Correlated private inspection queries." {:visibility :discoverable})

(defn runs [options]
  (cap/unwrap! (tool/inspection-list-runs options)))

(defn model-exchanges [run-id cursor]
  (cap/unwrap!
    (tool/inspection-model-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn capability-calls [run-id cursor]
  (cap/unwrap!
    (tool/inspection-capability-calls
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn generated-sources [run-id cursor]
  (cap/unwrap!
    (tool/inspection-generated-sources
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn effective-preludes [run-id cursor]
  (cap/unwrap!
    (tool/inspection-effective-preludes
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn provider-exchanges [run-id cursor]
  (cap/unwrap!
    (tool/inspection-provider-exchanges
      (cap/with-cursor {"run_id" run-id "limit" 100} cursor))))
