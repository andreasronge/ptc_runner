(ns example.workflow "Orchestrates reader and writer agents across two missions.")

(defn- returned-value [outcome]
  (get (agent.core/fail-outcome outcome) :value))

(defn run [input]
  (let [source (get input "source")
        destination (get input "destination")
        read-outcome
        (agent.core/run-outcome
          (str "Read " source " with example.reader/read-source-page, passing nil first. "
               "Concatenate item text and follow next_cursor until nil. Return its exact text.")
          {"mission" "reader" "max_turns" 4})
        text (returned-value read-outcome)
        write-outcome
        (agent.core/run-outcome
          (str "Write the following text to " destination
               " with example.writer/write-result, then return the destination path.\n\n" text)
          {"mission" "writer" "max_turns" 4})]
    (return
      {"read" text
       "written" (returned-value write-outcome)})))
