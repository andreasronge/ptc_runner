(ns files "Read the published brief from two upstream servers." {:visibility :prompt})


(defn briefs
  "Return one bounded page from each published brief."
  {:effect :read :signature "() -> :string"}
  []
  (let [notes (response/value (tool/notes.read {"path" "brief.txt"}))
        policy (response/value (tool/policy.read {"path" "brief.txt"}))]
    (str (get-in notes ["items" 0 "text"]) (get-in policy ["items" 0 "text"]))))
