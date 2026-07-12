(ns agent.feedback "Bounded correction messages for agent workflows." {:visibility :prompt})

(defn protocol-error [action]
  (str "Protocol error: " (get action :reason)
       ". Call run_ptc_lisp exactly once with one program string."))

(defn evaluation-error [evaluation]
  (str "The PTC-Lisp evaluation did not return successfully ("
       (get evaluation :outcome) "). Send one corrected run_ptc_lisp call."))
