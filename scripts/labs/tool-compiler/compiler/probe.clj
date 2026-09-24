(ns lab.probe
  "Two ways to look at a page: read what it says, and try a recipe on it.
  The compiler discovers selectors by probing, because no tool returns markup."
  {:visibility :prompt})

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(defn- search-url! [url]
  (if (or (ends-with? url "/quotes") (ends-with? url "/validation"))
    url
    (fail {"code" "url_not_search_visible"
           "message" "compiler probes are limited to the learning and validation pages"})))

(defn- snapshot-of [url]
  (let [handle (get (value! (tool/web.open {"url" (search-url! url)})) "handle_id")
        captured (value! (tool/web.capture {"handle_id" handle}))]
    {"handle" handle "snapshot_id" (get captured "snapshot_id")}))

(defn read-text
  "Return the first page of the page's text. Use it to learn what records the
  page actually contains before guessing any selector."
  {:signature "(url :string) -> {content :string, next_cursor :string?}" :effect :read}
  [url]
  (let [page (snapshot-of url)
        text (value! (tool/web.read {"snapshot_id" (get page "snapshot_id")
                                     "format" "text"}))]
    (value! (tool/web.close {"handle_id" (get page "handle")}))
    text))

(defn try-recipes
  "Try many candidate recipes against ONE capture of the page. Each candidate is
  {container, text_selector, author_selector}. Returns the records each one
  extracts, so a whole round of guesses costs a single page load."
  {:signature "(url :string, candidates [{container :string, text_selector :string, author_selector :string}]) -> [{candidate :map, records [:map]}]" :effect :read}
  [url candidates]
  (let [page (snapshot-of url)
        snapshot-id (get page "snapshot_id")
        attempt (fn [candidate]
                  (let [extracted (value! (tool/web.extract
                                            {"snapshot_id" snapshot-id
                                             "container" (get candidate "container")
                                             "fields" [{"name" "text" "selector" (get candidate "text_selector")}
                                                       {"name" "author" "selector" (get candidate "author_selector")}]
                                             "limit" 20}))]
                    {"candidate" candidate "records" (get extracted "records")}))
        results (mapv attempt candidates)]
    (value! (tool/web.close {"handle_id" (get page "handle")}))
    results))
