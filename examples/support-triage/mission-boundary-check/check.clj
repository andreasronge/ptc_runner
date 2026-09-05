(ns boundary.check "Sends one fixed program to both missions so the grant decides." {:visibility :prompt})

;; `kernel/eval` and `kernel/eval-with` hand back the mission evaluation
;; record. Its `outcome` is `:returned` when the program completed and
;; `:evaluation_error` when the mission refused it, with the refusal text under
;; `details`.
(defn- returned [record]
  (if (= (get record "outcome") :returned)
    (get record "value")
    (fail {:kind "triage-grant-missing" :record record})))

;; Only the refusal a missing grant produces counts. The escalation mission
;; answering is the boundary standing open; any other error is a broken check,
;; not a demonstrated boundary. Both fail the run, each under its own kind.
(defn- refused [record expected]
  (let [message (or (get-in record ["details" "message"]) "")]
    (cond
      (= (get record "outcome") :returned)
      (fail {:kind "grant-boundary-open" :record record})

      (not (str/includes? message expected))
      (fail {:kind "unexpected-refusal" :expected expected :record record})

      ;; The unknown-namespace refusal goes on to list every namespace the
      ;; sandbox does offer; the clause before that list is the refusal itself.
      :else
      (first (str/split message #"\. Available")))))

;; Both probes are `(program ...)` literals, so the same source reaches both
;; missions and only the mission's own grants can decide the outcome.
(defn- read-mission-data [mission]
  (kernel/eval mission (program (return (count data/tickets)))))

(defn- call-mission-component [mission ticket]
  (kernel/eval-with mission (program (return (triage.rules/priority data/params))) ticket))

(defn run
  "Report what the triage grant allows and what the escalation grant refuses."
  {:signature "(input :map) -> :map"}
  [input]
  (let [ticket (get input "probe_ticket")]
    (return
      {"granted" {"mission" "triage"
                  "tickets_visible" (returned (read-mission-data "triage"))
                  "probe_priority" (returned (call-mission-component "triage" ticket))}
       "denied" {"mission" "escalation"
                 "mission_data" (refused (read-mission-data "escalation")
                                         "is not a granted data name")
                 "mission_component" (refused (call-mission-component "escalation" ticket)
                                              "unknown namespace triage.rules/")}})))
