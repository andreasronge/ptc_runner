(ns dabstep.review
  "Shared rendering and comparison for a reviewer that receives a retained
  REPL session and answers with its own measurement."
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

(defn- ratio [country]
  (let [total (get country "total_volume")]
    (if (or (nil? total) (== 0 total))
      0
      (/ (get country "fraudulent_volume") total))))

(defn top-country
  "Country whose fraudulent volume is the largest share of its total volume."
  {:signature "(countries [:map]) -> :string?"}
  [countries]
  (get (first (sort-by ratio > countries)) "ip_country"))

(defn- volumes-by-country [countries]
  (into {}
        (map (fn [country]
               [(get country "ip_country")
                [(get country "fraudulent_volume") (get country "total_volume")]])
             countries)))

(defn- same-cent? [a b]
  (< (abs (- a b)) 0.005))

(defn same-measurements?
  "True when two derivations report the same countries, each once, and every
  volume agrees to the cent. Summation order moves a double by far less than
  that; a dropped transaction moves it by at least one cent."
  {:signature "(a [:map], b [:map]) -> :boolean"}
  [a b]
  (let [va (volumes-by-country a)
        vb (volumes-by-country b)]
    (and (= (count va) (count a))
         (= (count vb) (count b))
         (= (set (keys va)) (set (keys vb)))
         (every? (fn [[country [fa ta]]]
                   (let [[fb tb] (get vb country)]
                     (and (same-cent? fa fb) (same-cent? ta tb))))
                 va))))
