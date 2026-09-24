(ns lab.normaliser "Text normalisation subject with a small tokenizer." {:visibility :prompt})

(defn- separator?
  "Recognise characters that separate tokens."
  [character]
  (contains? #{" " "\n" "\t" "," "." ":" ";" "!" "?"} character))

(defn- append-character
  "Append a character to the current token."
  [state character]
  (assoc state "current" (str (get state "current" "") character)))

(defn- finish-token
  "Move a non-empty current token into the token vector."
  [state]
  (let [current (get state "current" "")]
    (if (= current "")
      state
      {"current" ""
       "tokens" (conj (get state "tokens" []) current)})))

(defn- tokenize
  "Split text on the subject's fixed separator set."
  [text]
  (let [state
        (reduce
          (fn [state character]
            (if (separator? character)
              (finish-token state)
              (append-character state character)))
          {"current" "" "tokens" []}
          (map str text))]
    (get (finish-token state) "tokens")))

(defn- canonical-token
  "Lowercase one token and optionally discard short values."
  [token minimum]
  (let [normal (clojure.string/lower-case token)]
    (if (< (count normal) minimum) nil normal)))

(defn normalise
  "Tokenize text, lowercase tokens, and remove tokens below the minimum length."
  {:signature "(input :map) -> :map"}
  [input]
  (let [minimum (get input "minimum_length" 2)
        tokens (tokenize (get input "text" ""))
        normal (filter some? (map #(canonical-token % minimum) tokens))]
    (return {"tokens" (vec normal)
             "text" (clojure.string/join " " normal)})))
