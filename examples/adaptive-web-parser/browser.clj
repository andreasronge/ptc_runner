(ns demo.browser "A browser facade that keeps MCP details out of the workflow.")

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(defn- capture-page [url]
  (let [opened (value! (tool/web.open {"url" url}))
        handle (get opened "handle_id")
        captured (value! (tool/web.capture {"handle_id" handle}))]
    {"handle_id" handle "captured" captured}))

(defn- close-result [page extracted]
  (let [captured (get page "captured")
        closed (value! (tool/web.close {"handle_id" (get page "handle_id")}))]
    {"url" (get captured "url")
     "records" (get extracted "records")
     "closed" (get closed "closed")}))

(defn query [url]
  (let [page (capture-page url)
        extracted (site.recipe/extract (get (get page "captured") "snapshot_id"))]
    (return (close-result page extracted))))

(defn query-with-recipe [url recipe]
  (let [page (capture-page url)
        captured (get page "captured")
        response (tool/web.extract
                   {"snapshot_id" (get captured "snapshot_id")
                    "container" (get recipe "container")
                    "fields" [{"name" "text" "selector" (get recipe "text_selector")}
                              {"name" "author" "selector" (get recipe "author_selector")}]
                    "limit" 10})
        extracted (value! response)]
    (return (close-result page extracted))))
