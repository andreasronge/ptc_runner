(ns inspection "Correlated private inspection queries." {:visibility :discoverable})

(defn- unwrap [response]
  (if (= :ok (get response :status))
    (get response :value)
    response))

(defn- with-cursor [arguments cursor]
  (if (nil? cursor)
    arguments
    (assoc arguments "cursor" cursor)))

(defn runs [options]
  (unwrap (tool/inspection-list-runs options)))

(defn model-exchanges [run-id cursor]
  (unwrap
    (tool/inspection-model-exchanges
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn capability-calls [run-id cursor]
  (unwrap
    (tool/inspection-capability-calls
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn generated-sources [run-id cursor]
  (unwrap
    (tool/inspection-generated-sources
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn effective-preludes [run-id cursor]
  (unwrap
    (tool/inspection-effective-preludes
      (with-cursor {"run_id" run-id "limit" 100} cursor))))

(defn provider-exchanges [run-id cursor]
  (unwrap
    (tool/inspection-provider-exchanges
      (with-cursor {"run_id" run-id "limit" 100} cursor))))
