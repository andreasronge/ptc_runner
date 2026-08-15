(ns debug.nav
  "Coarse, bounded navigation over immutable private run evidence. The mission must select its correlated inspection snapshot provider under the conventional name debug.nav."
  {:visibility :prompt})

(defn runs
  "List captured runs. Example: (debug.nav/runs {\"status\" \"error\" \"limit\" 5})."
  {:signature "(options :map) -> :map"}
  [options]
  (cap/unwrap! (tool/debug.nav.runs options)))

(defn open
  "Open a run and discover available collections and direct filter names. Example: (debug.nav/open \"run-id\")."
  {:signature "(run-id :string) -> :map"}
  [run-id]
  (cap/unwrap! (tool/debug.nav.open {"run_id" run-id})))

(defn read
  "Read one evidence page. Put collection and advertised filters directly in options; do not nest them under filters. Example: (debug.nav/read \"run-id\" {\"collection\" \"turns\" \"evaluation_id\" \"mission-evaluation-9\"})."
  {:signature "(run-id :string, options :map) -> :map"}
  [run-id options]
  (cap/unwrap! (tool/debug.nav.read (assoc options "run_id" run-id))))

(defn component-source
  "Read captured source for one component. Example: (debug.nav/component-source \"run-id\" \"workspace\")."
  {:signature "(run-id :string, component-id :string) -> :map"}
  [run-id component-id]
  (read run-id
        {"collection" "prelude_sources"
         "component_id" component-id
         "limit" 20}))

(defn evaluation
  "Group the activity, generated source, turns, and errors associated with one exact evaluation id."
  {:signature "(run-id :string, evaluation-id :string) -> :map"}
  [run-id evaluation-id]
  {"run_id" run-id
   "activity"
   (get
     (read run-id
           {"collection" "activity"
            "evaluation_id" evaluation-id
            "limit" 20})
     "items")
   "generated_sources"
   (get
     (read run-id
           {"collection" "generated_sources"
            "evaluation_id" evaluation-id
            "limit" 20})
     "items")
   "turns"
   (get
     (read run-id
           {"collection" "turns"
            "evaluation_id" evaluation-id
            "limit" 20})
     "items")
   "execution_errors"
   (get
     (read run-id
           {"collection" "execution_errors"
            "evaluation_id" evaluation-id
            "limit" 20})
     "items")})

(defn- called-components
  [turns]
  (filter
    (fn [component-id] component-id)
    (distinct
      (mapcat
        (fn [turn]
          (mapcat
            (fn [generated]
              (map
                (fn [call] (get call "component_id"))
                (get generated "prelude_calls")))
            (get turn "generated")))
        turns))))

(defn- dependency-graphs
  [run]
  (filter
    (fn [graph] graph)
    (concat
      [(get run "workflow_prelude")]
      (map
        (fn [mission] (get mission "prelude"))
        (vals (get run "missions"))))))

(defn- direct-dependencies
  [run called]
  (distinct
    (mapcat
      (fn [graph]
        (let [component-ids (get graph "component_ids")
              dependency-indices (get graph "dependency_indices")]
          (mapcat
            (fn [called-id]
              (let [matches
                    (filter
                      (fn [index] (= (nth component-ids index) called-id))
                      (range (count component-ids)))
                    index (first matches)]
                (if index
                  (map
                    (fn [dependency-index]
                      (nth component-ids dependency-index))
                    (nth dependency-indices index))
                  [])))
            called)))
      (dependency-graphs run))))

(defn- turn-summary
  [turn]
  {"turn" (get turn "turn")
   "stream_id" (get turn "stream_id")
   "messages_added" (get turn "messages_added")
   "generated"
   (map
     (fn [generated]
       {"evaluation_id" (get generated "evaluation_id")
        "parent_evaluation_id" (get generated "parent_evaluation_id")
        "environment" (get generated "environment")
        "mission_name" (get generated "mission_name")
        "source" (get generated "source")
        "source_hash" (get generated "source_hash")
        "prelude_calls" (get generated "prelude_calls")})
     (get turn "generated"))
   "feedback" (get turn "feedback")})

(defn- component-link
  [run-id component-id]
  {"rel" "component-source"
   "component_id" component-id
   "function" "debug.nav/component-source"
   "arguments" [run-id component-id]
   "call"
   (str
     "(debug.nav/component-source \""
     run-id
     "\" \""
     component-id
     "\")")})

(defn- evaluation-link
  [run-id error]
  (let [evaluation-id (get error "evaluation_id")]
    {"rel" "evaluation"
     "evaluation_id" evaluation-id
     "function" "debug.nav/evaluation"
     "arguments" [run-id evaluation-id]
     "call"
     (str
       "(debug.nav/evaluation \""
       run-id
       "\" \""
       evaluation-id
       "\")")}))

(defn latest-failure
  "Return one latest failed run as a bounded incident: errors, reconstructed programs and feedback, called component sources, immediate dependency sources, collection metadata, and copyable follow-up links."
  {:signature "(options :map) -> :map"}
  [options]
  (let [listing (runs (assoc options "status" "error" "limit" 1))
        run (first (get listing "items"))
        run-id (get run "run_id")]
    (if run-id
      (let [opened (open run-id)
            errors-page
            (read run-id {"collection" "execution_errors" "limit" 20})
            turns-page (read run-id {"collection" "turns" "limit" 20})
            errors (get errors-page "items")
            turns (get turns-page "items")
            called (called-components turns)
            dependencies (direct-dependencies run called)
            related (distinct (concat called dependencies))
            sources
            (mapcat
              (fn [component-id]
                (get (component-source run-id component-id) "items"))
              related)]
        {"run" run
         "evidence"
         {"collections" (get opened "collections")
          "inspection" (get opened "inspection")
          "errors_complete?" (= (get errors-page "next_cursor") nil)
          "turns_complete?" (= (get turns-page "next_cursor") nil)}
         "execution_errors" errors
         "turns" (map turn-summary turns)
         "called_components" called
         "dependency_components" dependencies
         "prelude_sources" sources
         "links"
         (concat
           [{"rel" "open-run"
             "function" "debug.nav/open"
             "arguments" [run-id]
             "call" (str "(debug.nav/open \"" run-id "\")")}]
           (map (fn [error] (evaluation-link run-id error)) errors)
           (map (fn [component-id] (component-link run-id component-id)) related))})
      (fail "no failed run is available in the immutable capture"))))
