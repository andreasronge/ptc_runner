(ns aggregate "Provider-free aggregation of evaluation trials." {:visibility :prompt})

;; Aggregation is pure. It selects no LLM and no mission provider, so it cannot
;; run a trial, retry one, or reach a model — it can only count what the trials
;; already produced. That is what makes its verdict evidence rather than another
;; opinion, and it is why this is a separate manifest from the trials.
;;
;; The verdict is deliberately conservative. Every check below can only move a
;; candidate from accepted toward inconclusive or rejected, never the other way,
;; because the failure mode that matters is a candidate that looks good on the
;; cases its own author cited.

(defn- trials-for [trials subject]
  (filterv #(= subject (get % "subject")) trials))

(defn- key-of [trial]
  (str (get-in trial ["case" "id"]) "#" (get trial "repetition")))

(defn- passed? [trial] (true? (get trial "passed")))

(defn- rate [trials]
  (if (empty? trials)
    0
    (/ (count (filterv passed? trials)) (count trials))))

(defn- by-set [trials set-name]
  (filterv #(= set-name (get-in % ["case" "set"])) trials))

;; A candidate trial must carry an override source hash and a baseline must not.
;; Trusting the declared subject alone would let a mislabelled artifact compare
;; a run against itself and report a perfect improvement.
(defn- subject-consistent? [trial]
  (let [declared (get trial "subject")
        overridden (get-in trial ["run_identity" "override_source_hash"])]
    (if (= declared "candidate") (string? overridden) (nil? overridden))))

(defn- identity-drift [trials]
  (let [candidates (distinct (mapv #(get-in % ["candidate" "source_hash"]) trials))
        bases (distinct (mapv #(get-in % ["candidate" "base_source_hash"]) trials))
        components (distinct (mapv #(get-in % ["candidate" "component_id"]) trials))]
    (cond
      (> (count components) 1) "trials name more than one component"
      (> (count bases) 1) "trials were derived from more than one base"
      (> (count candidates) 1) "trials evaluate more than one candidate"
      :else nil)))

;; Every case must appear on both sides. A pair missing its baseline cannot show
;; an improvement, and a pair missing its candidate hides a trial that failed to
;; produce an artifact at all.
(defn- unpaired [baseline candidate]
  (let [baseline-keys (mapv key-of baseline)
        candidate-keys (mapv key-of candidate)]
    (into
      (filterv (fn [k] (not (some #(= % k) candidate-keys))) baseline-keys)
      (filterv (fn [k] (not (some #(= % k) baseline-keys))) candidate-keys))))

(defn- regressions [baseline candidate set-name]
  (let [before (by-set baseline set-name)
        after (into {} (mapv (fn [t] [(key-of t) t]) (by-set candidate set-name)))]
    (filterv
      (fn [trial]
        (let [match (get after (key-of trial))]
          (and (passed? trial) (or (nil? match) (not (passed? match))))))
      before)))

(defn- decide [problems held-out-regressions gained]
  (cond
    (seq problems) {"verdict" "invalid" "reasons" problems}
    (seq held-out-regressions)
    {"verdict" "reject"
     "reasons" ["candidate regresses held-out cases it did not cite"]}
    (not gained) {"verdict" "inconclusive" "reasons" ["candidate improves no cited case"]}
    :else {"verdict" "accept" "reasons" []}))

(defn run
  "Aggregates trial artifacts into one bounded evaluation."
  [input]
  (let [trials (get input "trials")]
    (if (or (not (vector? trials)) (empty? trials))
      (fail {"error" "no-trials"})
      (let [baseline (trials-for trials "baseline")
            candidate (trials-for trials "candidate")
            missing (unpaired baseline candidate)
            drift (identity-drift trials)
            mislabelled (filterv #(not (subject-consistent? %)) trials)
            held-out (regressions baseline candidate "held-out")
            regression-set (regressions baseline candidate "regression")
            problems (into
                       (into
                         (if drift [drift] [])
                         (if (empty? missing)
                           []
                           [(str "unpaired trials: " (join ", " missing))]))
                       (if (empty? mislabelled)
                         []
                         [(str (count mislabelled) " trial(s) disagree with their run identity")]))
            motivating-before (rate (by-set baseline "motivating"))
            motivating-after (rate (by-set candidate "motivating"))
            gained (> motivating-after motivating-before)
            outcome (decide problems (into held-out regression-set) gained)]
        (return
          {"verdict" (get outcome "verdict")
           "reasons" (get outcome "reasons")
           "candidate" (get-in (first trials) ["candidate"])
           "counts" {"trials" (count trials)
                     "baseline" (count baseline)
                     "candidate" (count candidate)}
           "rates" {"motivating_before" motivating-before
                    "motivating_after" motivating-after
                    "regression_before" (rate (by-set baseline "regression"))
                    "regression_after" (rate (by-set candidate "regression"))
                    "held_out_before" (rate (by-set baseline "held-out"))
                    "held_out_after" (rate (by-set candidate "held-out"))}
           "regressed_cases" (mapv #(get-in % ["case" "id"])
                                   (into held-out regression-set))})))))
