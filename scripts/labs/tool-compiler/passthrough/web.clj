(ns lab.web
  "Raw page tools, passed through without interpretation. Arm A holds no domain
  knowledge: every selector, every cursor, and every decision is the model's."
  {:visibility :prompt})

(defn- value! [response]
  (if (= :ok (get response :status)) (get response :value) (fail response)))

(defn open
  "Open a URL and return a page handle."
  {:signature "(url :string) -> {handle_id :string}" :effect :read}
  [url]
  (value! (tool/web.open {"url" url})))

(defn capture
  "Snapshot the open page. Returns metadata and a small preview, not the page."
  {:signature "(handle_id :string) -> {snapshot_id :string, url :string, title :string}" :effect :read}
  [handle-id]
  (value! (tool/web.capture {"handle_id" handle-id})))

(defn read-page
  "Read one bounded page of the snapshot as markdown. Pass nil first, then
  next_cursor, until it is nil."
  {:signature "(snapshot_id :string, cursor :string?) -> {content :string, next_cursor :string?}" :effect :read}
  [snapshot-id cursor]
  (let [arguments (if cursor
                    {"snapshot_id" snapshot-id "format" "markdown" "cursor" cursor}
                    {"snapshot_id" snapshot-id "format" "markdown"})]
    (value! (tool/web.read arguments))))

(defn find-text
  "Find literal passages in the snapshot. Pass nil first, then next_cursor."
  {:signature "(snapshot_id :string, query :string, cursor :string?) -> {matches [{excerpt :string}], next_cursor :string?}" :effect :read}
  [snapshot-id query cursor]
  (let [arguments (if cursor
                    {"snapshot_id" snapshot-id "query" query "cursor" cursor}
                    {"snapshot_id" snapshot-id "query" query})]
    (value! (tool/web.find arguments))))

(defn extract
  "Extract one page of records with CSS selectors. Each field accepts an
  optional selector, source (text, html, or attribute), attribute name,
  multiple flag, and required flag. Pass nil as cursor for the first page, then
  next_cursor until it is nil."
  {:signature "(snapshot_id :string, container :string, fields [{name :string, selector :string?, source :string?, attribute :string?, multiple :bool?, required :bool?}], limit :int, cursor :string?) -> {records [:map], next_cursor :string?, matched_containers :int, omitted_records :int, result_truncated :bool, recipe_hash :string}" :effect :read}
  [snapshot-id container fields limit cursor]
  (let [arguments {"snapshot_id" snapshot-id
                   "container" container
                   "fields" fields
                   "limit" limit}]
    (value!
      (tool/web.extract
        (if cursor (assoc arguments "cursor" cursor) arguments)))))

(defn close
  "Release the page handle."
  {:signature "(handle_id :string) -> {closed :bool}" :effect :read}
  [handle-id]
  (value! (tool/web.close {"handle_id" handle-id})))
