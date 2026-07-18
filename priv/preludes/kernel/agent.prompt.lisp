(ns agent.prompt "Domain-blind system-prompt policy for agent.core." {:visibility :discoverable})

(defn initial-state [_cfg]
  {:revision 0})

(defn render [state]
  (if (map? state)
    (str "PTC_AGENT_PROMPT_V1\n\n"
         "Instructions\n"
         "Use the run_ptc_lisp tool exactly once per turn with one program string.\n"
         "End successful programs with (return value) and explicit failures with (fail value).\n"
         "Do not answer in prose.\n\n"
         "PTC-Lisp\n"
         "- PTC-Lisp is a bounded Clojure-like language.\n"
         "- Use let, fn, def/defn, if, loop/recur, map/filter/reduce, and collection helpers.\n"
         "- Also available: cond/case, ->/->>, for/doseq, string, set, regex, math, date/time, and json helpers.\n"
         "- Decoded JSON maps use string keys; read them with get/get-in.\n"
         "- Value references are values; call only function references.\n"
         "- Call granted capabilities only with the exact tool/... forms shown below.\n"
         "- Fixed namespaces: clojure.core/core, clojure.string/str/string, clojure.set/set, clojure.walk/walk, regex, Math, System, Boolean, numeric/date/time namespaces, data, tool, and json.\n"
         "- No ns/require/refer/import, user-defined macros, eval/read-string, host file I/O, or general Java interop.\n\n"
         "Examples\n"
         "(let [rows (get data/input \"rows\") active (filter #(true? (get % \"active\")) rows)] (return (mapv #(get % \"id\") active)))\n"
         "(let [response (tool/exact-name {\"query\" \"value\"})] (if (= :ok (get response :status)) (return (get response :value)) (fail response)))\n\n"
         "Mission API and limits (deterministic JSON)\n"
         (kernel/mission-model-context))
    nil))

(defn transition [state event]
  (if (and (map? state) (map? event))
    state
    nil))
