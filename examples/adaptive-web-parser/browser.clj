(ns demo.browser "A browser facade that keeps MCP details out of the workflow.")

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(defn query [url]
  (let [opened (value! (tool/web.open {"url" url}))
        handle (get opened "handle_id")
        captured (value! (tool/web.capture {"handle_id" handle}))
        extracted (site.recipe/extract (get captured "snapshot_id"))
        closed (value! (tool/web.close {"handle_id" handle}))]
    (return {"url" (get captured "url")
             "records" (get extracted "records")
             "closed" (get closed "closed")})))
