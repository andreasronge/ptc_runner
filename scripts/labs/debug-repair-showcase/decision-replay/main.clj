(ns main "One recorded model decision; no generated action is executed." {:visibility :prompt})
(defn run "Send the prepared request exactly once and retain its response." [input]
  (return (llm/request (get input "request"))))
