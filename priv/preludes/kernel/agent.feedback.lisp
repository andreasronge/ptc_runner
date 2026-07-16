(ns agent.feedback "Bounded correction messages for agent workflows." {:visibility :prompt})

(defn protocol-error [action]
  (str "Protocol error: " (get action :reason)
       ". Call run_ptc_lisp exactly once with one program string."))

(defn evaluation-error [evaluation]
  (let [outcome (get evaluation :outcome)
        code (or (get evaluation :kind)
                 (get evaluation :reason)
                 outcome)
        message (get-in evaluation [:details :message])]
    (str "The PTC-Lisp evaluation did not return successfully. "
         "outcome=" outcome "; error_code=" code
         (if message (str "; message=" message) "")
         ". Send one corrected run_ptc_lisp call.")))
