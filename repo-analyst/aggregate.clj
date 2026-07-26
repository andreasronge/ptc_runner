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
(defn- occurrences [trials k]
  (count (filterv #(= k (key-of %)) trials)))

;; Membership is not enough. A candidate side that ran one case twice is
;; "paired" under set semantics, and re-running a case until it passes is
;; exactly the manipulation this aggregate exists to refuse, so each key must
;; appear the same number of times on both sides.
(defn- unpaired [baseline candidate]
  (let [keys (distinct (into (mapv key-of baseline) (mapv key-of candidate)))]
    (filterv (fn [k] (not= (occurrences baseline k) (occurrences candidate k))) keys)))

(defn- regressions [baseline candidate set-name]
  (let [before (by-set baseline set-name)
        after (into {} (mapv (fn [t] [(key-of t) t]) (by-set candidate set-name)))]
    (filterv
      (fn [trial]
        (let [match (get after (key-of trial))]
          (and (passed? trial) (or (nil? match) (not (passed? match))))))
      before)))

;; Negative controls check the harness, not the candidate. If the case every
;; subject must pass fails, or the case every subject must fail passes, the
;; scoring itself is untrustworthy and no verdict about the candidate can be
;; drawn from the same run.
(defn- control-problems [baseline candidate]
  (let [controls (into (by-set baseline "negative-control")
                       (by-set candidate "negative-control"))
        must-pass (filterv #(includes? (get-in % ["case" "id"]) "always-passes") controls)
        must-fail (filterv #(includes? (get-in % ["case" "id"]) "always-fails") controls)]
    (into
      (if (some #(not (passed? %)) must-pass)
        ["negative control that every subject must pass did not pass"]
        [])
      (if (some passed? must-fail)
        ["negative control that every subject must fail passed"]
        []))))

;; Bounded: `reasons` caps each entry at 500 characters, and an unbounded join
;; would make the aggregate fail its own contract exactly when it has the most
;; to report.
(defn- unpaired-reason [missing]
  (let [shown (take 8 missing)]
    (str "unpaired trials (" (count missing) "): " (join ", " shown)
         (if (> (count missing) 8) ", …" ""))))

(defn- decide [problems held-out-regressions gained]
  (cond
    (seq problems) {"verdict" "invalid" "reasons" problems}
    (seq held-out-regressions)
    {"verdict" "reject"
     "reasons" [(str "candidate regresses "
                     (count held-out-regressions)
                     " case(s) that passed before")]}
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
            unrecognised (- (count trials) (+ (count baseline) (count candidate)))
            held-out (regressions baseline candidate "held-out")
            regression-set (into (regressions baseline candidate "regression")
                                 (regressions baseline candidate "motivating"))
            controls (control-problems baseline candidate)
            problems (into
                       (into
                         (if drift [drift] [])
                         (if (empty? missing)
                           []
                           [(unpaired-reason missing)]))
                       (into
                         (if (empty? mislabelled)
                           []
                           [(str (count mislabelled) " trial(s) disagree with their run identity")])
                         (into
                           (if (> unrecognised 0)
                             [(str unrecognised " trial(s) declare no recognised subject")]
                             [])
                           controls)))
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
           "regressed_cases" (distinct (mapv #(get-in % ["case" "id"])
                                             (into held-out regression-set)))})))))
