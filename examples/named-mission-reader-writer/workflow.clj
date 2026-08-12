(ns example.workflow "Orchestrates reader and writer agents across two missions.")

(defn- returned-value [outcome role]
  (if (= :returned (get outcome :status))
    (get outcome :value)
    (fail {:status :error :kind :agent-failed :reason role :outcome outcome})))

(defn run [input]
  (let [source (get input "source")
        destination (get input "destination")
        read-outcome
        (agent.core/run-outcome
          (str "Read " source " with example.reader/read-source. Return its exact text.")
          {"mission" "reader" "max_turns" 4})
        text (returned-value read-outcome :reader)
        write-outcome
        (agent.core/run-outcome
          (str "Write the following text to " destination
               " with example.writer/write-result, then return the destination path.\n\n" text)
          {"mission" "writer" "max_turns" 4})]
    (return
      {"read" text
       "written" (returned-value write-outcome :writer)})))
