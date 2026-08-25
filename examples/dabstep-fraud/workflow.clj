(ns dabstep.workflow "Thin workflow over the shipped agent loop.")

(defn run [input]
  (agent.core/run
    (str (get input "task") "\n\n" (get input "guidelines"))
    {"mission" "analysis"
     "model" (get input "model")
     "max_turns" (get input "max_turns")}))
