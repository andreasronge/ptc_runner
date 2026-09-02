(ns dabstep.review
  "Shared rendering for a reviewer that receives a retained REPL session."
  {:visibility :discoverable})

(defn- field [m keyword-key string-key]
  (or (get m keyword-key) (get m string-key)))

(defn- execution [program]
  (field program :execution "execution"))

(defn reviewable-programs
  "Keep successful REPL steps and omit rolled-back evaluations."
  {:signature "(programs [:map]) -> [:map]"}
  [programs]
  (into []
        (filter (fn [program]
                  (let [outcome (field (execution program) :outcome "outcome")]
                    (or (= :continued outcome)
                        (= "continued" outcome)
                        (= :returned outcome)
                        (= "returned" outcome))))
                programs)))

(defn- numbered [programs]
  (join "\n\n---\n\n"
        (map (fn [i]
               (let [program (nth programs i)]
                 (str "STEP " (+ i 1) " — turn "
                      (field program :turn "turn") ", "
                      (field program :mission "mission")
                      "\nEXECUTION\n" (pr-str (execution program))
                      "\nSOURCE\n" (field program :source "source"))))
             (range (count programs)))))

(defn prompt
  "Render the task, input, analyzer result, and successful REPL steps."
  {:signature "(input :map, analyzer-result :map, programs [:map]) -> :string"}
  [input analyzer-result programs]
  (str (get input "review_task")
       "\n\nTASK\n" (get input "task")
       "\n\nINPUT\n"
       (json/generate-string (select-keys input ["task" "guidelines" "options"]))
       "\n\nANALYZER RESULT\n" (json/generate-string analyzer-result)
       "\n\nREPL SESSION\n" (numbered programs)))
