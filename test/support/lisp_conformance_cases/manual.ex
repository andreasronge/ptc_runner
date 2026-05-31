defmodule PtcRunner.TestSupport.LispConformanceCases.Manual do
  @moduledoc """
  Hand-seeded PTC-Lisp conformance cases.

  Keep these cases small, deterministic, and finite. Imported upstream suites
  should be converted into this same shape instead of being executed directly.
  """

  @doc """
  Returns the manual conformance seed set.
  """
  @spec all() :: [map()]
  def all do
    core_cases() ++
      string_cases() ++
      set_walk_cases() ++
      core_predicate_numeric_cases() ++
      core_sequence_map_cases() ++
      core_hof_control_cases() ++
      historical_regression_cases() ++
      core_bug_cases() ++
      candidate_unsupported_cases() ++
      java_candidate_unsupported_cases() ++
      java_match_cases() ++ java_bug_cases() ++ divergence_cases() ++ ptc_cases()
  end

  defp core_cases do
    [
      c("core/arithmetic-001", "clojure.core", ["+"], "(+ 1 2 3)", [:smoke, :numeric]),
      c("core/arithmetic-002", "clojure.core", ["+"], "(+)", [:edge, :numeric]),
      c("core/arithmetic-003", "clojure.core", ["*"], "(* 2 3 4)", [:smoke, :numeric]),
      c("core/arithmetic-004", "clojure.core", ["*"], "(*)", [:edge, :numeric]),
      c("core/arithmetic-005", "clojure.core", ["-"], "(- 10 3 2)", [:smoke, :numeric]),
      c("core/arithmetic-006", "clojure.core", ["/"], "(/ 12 3)", [:smoke, :numeric]),
      c("core/comparison-001", "clojure.core", ["<"], "(< 1 2 3)", [:smoke, :numeric]),
      c("core/comparison-002", "clojure.core", [">="], "(>= 3 3 1)", [:edge, :numeric]),
      c("core/equality-001", "clojure.core", ["="], "(= {:a 1} {:a 1})", [:smoke]),
      c("core/truthiness-001", "clojure.core", ["and"], "(and)", [:edge, :truthiness]),
      c("core/truthiness-002", "clojure.core", ["and"], "(and 1 2 :ok)", [:smoke, :truthiness]),
      c("core/truthiness-003", "clojure.core", ["and"], "(and 1 nil :no)", [:edge, :truthiness]),
      c("core/truthiness-004", "clojure.core", ["or"], "(or)", [:edge, :truthiness]),
      c("core/truthiness-005", "clojure.core", ["or"], "(or nil false :ok)", [:smoke, :truthiness]),
      c("core/control-001", "clojure.core", ["if"], "(if true :yes :no)", [:smoke]),
      c("core/control-002", "clojure.core", ["if"], "(if nil :yes :no)", [:edge]),
      c("core/control-003", "clojure.core", ["when"], "(when true 1 2 3)", [:smoke]),
      c("core/control-004", "clojure.core", ["cond"], "(cond false 1 nil 2 :else 3)", [:smoke]),
      c("core/control-005", "clojure.core", ["case"], "(case :b :a 1 :b 2 3)", [:smoke]),
      c("core/binding-001", "clojure.core", ["let"], "(let [x 1 y (+ x 2)] y)", [:smoke]),
      c("core/binding-002", "clojure.core", ["let"], "(let [[x & xs] [1 2 3]] xs)", [
        :destructuring
      ]),
      c("core/binding-003", "clojure.core", ["let"], "(let [{:keys [a]} {:a 7}] a)", [
        :destructuring
      ]),
      c("core/fn-001", "clojure.core", ["fn"], "((fn [x] (inc x)) 1)", [:smoke]),
      c("core/fn-002", "clojure.core", ["fn"], "((fn [x & xs] xs) 1 2 3)", [
        :edge
      ]),
      c("core/fn-003", "clojure.core", ["defn"], "(do (defn add2 [x] (+ x 2)) (add2 3))", [
        :smoke
      ]),
      c("core/apply-001", "clojure.core", ["apply"], "(apply + [1 2 3])", [:smoke]),
      c("core/apply-002", "clojure.core", ["apply"], "(apply str [\"a\" \"b\"])", [:string]),
      c("core/collection-001", "clojure.core", ["map"], "(map inc [1 2 3])", [
        :collection
      ]),
      c("core/collection-002", "clojure.core", ["filter"], "(filter odd? [1 2 3 4])", [
        :collection
      ]),
      c("core/collection-003", "clojure.core", ["reduce"], "(reduce + [1 2 3 4])", [
        :collection
      ]),
      c("core/collection-004", "clojure.core", ["keep"], "(keep identity [nil 1 false 2])", [
        :collection
      ]),
      c("core/seq-001", "clojure.core", ["first"], "(first [1 2 3])", [:collection]),
      c("core/seq-002", "clojure.core", ["rest"], "(rest [1])", [:edge, :collection]),
      c("core/seq-003", "clojure.core", ["next"], "(next [1])", [:edge, :collection]),
      c("core/seq-004", "clojure.core", ["seq"], "(seq [])", [:edge, :collection]),
      c("core/map-001", "clojure.core", ["get"], "(get {:a 1} :a)", [:smoke]),
      c("core/map-002", "clojure.core", ["get"], "(get {:a 1} :b :missing)", [:edge]),
      bug_case(
        "core/find-bug-001",
        "clojure.core",
        ["find"],
        "(find {:a 1} :a)",
        "GAP-S09",
        "PTC-Lisp implements find as predicate-first search, but Clojure find is map-entry lookup."
      ),
      bug_case(
        "core/find-missing-key-bug-001",
        "clojure.core",
        ["find"],
        "(find {:a 1} :b)",
        "GAP-S09",
        "Clojure find returns nil for missing map keys; PTC-Lisp currently treats the key as a collection argument."
      ),
      bug_case(
        "core/find-present-nil-value-bug-001",
        "clojure.core",
        ["find"],
        "(find {:a nil} :a)",
        "GAP-S09",
        "Clojure find returns a map entry for present nil values; PTC-Lisp currently treats the key as a collection argument."
      ),
      bug_case(
        "core/find-nil-bug-001",
        "clojure.core",
        ["find"],
        "(find nil :a)",
        "GAP-S09",
        "Clojure find returns nil for a nil map; PTC-Lisp currently treats the key as a collection argument."
      ),
      bug_case(
        "core/find-vector-index-bug-001",
        "clojure.core",
        ["find"],
        "(find [10 20] 1)",
        "GAP-S09",
        "Clojure find supports associative vectors by index; PTC-Lisp currently treats the index as a collection argument."
      ),
      bug_case(
        "core/find-vector-present-nil-bug-001",
        "clojure.core",
        ["find"],
        "(find [nil :b] 0)",
        "GAP-S09",
        "Clojure find returns a vector entry even when the indexed value is nil; PTC-Lisp currently treats the index as a collection argument."
      ),
      bug_case(
        "core/find-vector-out-of-range-bug-001",
        "clojure.core",
        ["find"],
        "(find [10 20] 2)",
        "GAP-S09",
        "Clojure find returns nil for out-of-range vector indexes; PTC-Lisp currently treats the index as a collection argument."
      ),
      bug_case(
        "core/find-vector-negative-index-bug-001",
        "clojure.core",
        ["find"],
        "(find [nil :b] -1)",
        "GAP-S09",
        "Clojure find returns nil for negative vector indexes; PTC-Lisp currently treats the index as a collection argument."
      ),
      bug_case(
        "core/find-set-nil-bug-001",
        "clojure.core",
        ["find"],
        ~S|(find #{nil} nil)|,
        "GAP-S09",
        "Clojure find raises for set inputs; PTC-Lisp currently applies predicate-search semantics and returns nil."
      ),
      c("core/map-003", "clojure.core", ["assoc"], "(assoc {:a 1} :b 2)", [:smoke]),
      c("core/map-004", "clojure.core", ["update"], "(update {:a 1} :a inc)", [:smoke]),
      c("core/map-005", "clojure.core", ["get-in"], "(get-in {:a {:b 2}} [:a :b])", [
        :smoke
      ]),
      c("core/map-006", "clojure.core", ["assoc-in"], "(assoc-in {:a {:b 1}} [:a :b] 2)", [
        :smoke
      ]),
      c("core/vector-001", "clojure.core", ["conj"], "(conj [1 2] 3)", [:collection]),
      c("core/vector-002", "clojure.core", ["into"], "(into [] [1 2 3])", [:collection]),
      c("core/vector-003", "clojure.core", ["empty"], "(empty [1 2 3])", [:collection]),
      div_case(
        "core/nth-oob-div-001",
        "clojure.core",
        ["nth"],
        "(nth [1 2] 5)",
        "DIV-26",
        nil,
        "Out-of-range collection access returns a signal value instead of raising."
      ),
      c("core/predicate-001", "clojure.core", ["nil?"], "(nil? nil)", [:smoke]),
      c("core/predicate-002", "clojure.core", ["some?"], "(some? false)", [:truthiness]),
      c("core/predicate-003", "clojure.core", ["number?"], "(number? 1.5)", [:numeric]),
      c("core/predicate-004", "clojure.core", ["string?"], "(string? \"x\")", [:string]),
      c("core/thread-001", "clojure.core", ["->"], "(-> {:a 1} (assoc :b 2) (get :b))", [
        :smoke
      ]),
      c("core/thread-002", "clojure.core", ["->>"], "(->> [1 2 3] (map inc) (reduce +))", [
        :collection
      ]),
      c("core/regex-001", "clojure.core", ["re-find"], ~S|(re-find #"\d+" "a12b")|, [
        :string
      ])
    ]
  end

  defp string_cases do
    [
      c("string/blank-001", "clojure.string", ["blank?"], ~S|(clojure.string/blank? "  ")|, [
        :string
      ]),
      unsupported_case(
        "string/capitalize-001",
        "clojure.string",
        ["capitalize"],
        ~S|(clojure.string/capitalize "abc")|,
        "Candidate in the audit; not implemented in PTC-Lisp."
      ),
      c(
        "string/includes-001",
        "clojure.string",
        ["includes?"],
        ~S|(clojure.string/includes? "abc" "b")|,
        [
          :string
        ]
      ),
      c("string/join-001", "clojure.string", ["join"], ~S|(clojure.string/join "," [1 2 3])|, [
        :string
      ]),
      c(
        "string/lower-001",
        "clojure.string",
        ["lower-case"],
        ~S|(clojure.string/lower-case "AbC")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/lower-case-number-bug-001",
        "clojure.string",
        ["lower-case"],
        "(clojure.string/lower-case 12)",
        "GAP-S139",
        "Clojure stringifies numeric lower-case input; PTC-Lisp currently raises a type error."
      ),
      bug_case(
        "string/includes-number-hit-bug-001",
        "clojure.string",
        ["includes?"],
        ~S|(clojure.string/includes? 123 "2")|,
        "GAP-S139",
        "Clojure stringifies numeric includes? receivers; PTC-Lisp currently raises a type error."
      ),
      bug_case(
        "string/includes-number-miss-bug-001",
        "clojure.string",
        ["includes?"],
        ~S|(clojure.string/includes? 123 "9")|,
        "GAP-S139",
        "Clojure stringifies numeric includes? receivers even when the substring is absent; PTC-Lisp currently raises a type error."
      ),
      c(
        "string/replace-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "a-b" "-" "+")|,
        [
          :string
        ]
      ),
      unsupported_case(
        "string/reverse-001",
        "clojure.string",
        ["reverse"],
        ~S|(clojure.string/reverse "abc")|,
        "Candidate in the audit; not implemented in PTC-Lisp."
      ),
      c(
        "string/split-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,b,c" #",")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/split-empty-regex-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "abc" #"")|,
        "GAP-S15",
        "Clojure drops the trailing empty element when splitting on an empty regex; PTC-Lisp keeps it."
      ),
      bug_case(
        "string/split-trailing-empty-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,b," #",")|,
        "GAP-S95",
        "Clojure drops trailing empty fields in the two-arity split form; PTC-Lisp currently keeps them."
      ),
      bug_case(
        "string/split-empty-input-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "" #",")|,
        "GAP-S95",
        "Clojure split on an empty string returns one empty string; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "string/split-limit-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "abc" #"" 2)|,
        "GAP-S25",
        "clojure.string/split supports a limit arity; PTC-Lisp currently only supports two arguments."
      ),
      bug_case(
        "string/split-limit-zero-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,,b" #"," 0)|,
        "GAP-S25",
        "clojure.string/split supports zero as a limit value; PTC-Lisp currently rejects the limit arity."
      ),
      bug_case(
        "string/split-limit-one-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,,b" #"," 1)|,
        "GAP-S25",
        "clojure.string/split supports one as a limit value; PTC-Lisp currently rejects the limit arity."
      ),
      bug_case(
        "string/split-limit-negative-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,,b" #"," -1)|,
        "GAP-S25",
        "clojure.string/split supports negative limit values; PTC-Lisp currently rejects the limit arity."
      ),
      bug_case(
        "string/join-nil-bug-001",
        "clojure.string",
        ["join"],
        "(clojure.string/join nil)",
        "GAP-S26",
        "Clojure treats nil as an empty collection for join; PTC-Lisp currently raises."
      ),
      bug_case(
        "string/join-separator-nil-bug-001",
        "clojure.string",
        ["join"],
        "(clojure.string/join nil [1 2])",
        "GAP-S26",
        "Clojure treats a nil separator as an empty string for join; PTC-Lisp currently raises."
      ),
      bug_case(
        "string/join-string-coll-bug-001",
        "clojure.string",
        ["join"],
        ~S|(clojure.string/join "ab")|,
        "GAP-S26",
        "Clojure joins seqable strings character by character; PTC-Lisp currently raises."
      ),
      bug_case(
        "string/join-map-coll-bug-001",
        "clojure.string",
        ["join"],
        ~S|(clojure.string/join "," {:a 1})|,
        "GAP-S26",
        "Clojure joins seqable map entries; PTC-Lisp currently raises."
      ),
      bug_case(
        "string/replace-fn-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "a1" #"\d" (fn [m] "X"))|,
        "GAP-S27",
        "clojure.string/replace accepts a replacement function; PTC-Lisp currently requires a string replacement."
      ),
      bug_case(
        "string/replace-fn-groups-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "a1b2" #"(\d)" (fn [[m g]] (str "<" g ">")))|,
        "GAP-S27",
        "clojure.string/replace passes match groups to replacement functions; PTC-Lisp currently rejects function replacements."
      ),
      bug_case(
        "string/replace-regex-backref-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "a1" #"(\d)" "<$1>")|,
        "GAP-S73",
        "Clojure regex replacement strings expand capture-group references; PTC-Lisp currently inserts them literally."
      ),
      bug_case(
        "string/replace-regex-invalid-dollar-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "a1" #"\d" "$$")|,
        "GAP-S73",
        "Clojure regex replacement strings reject invalid dollar group references; PTC-Lisp currently inserts them literally."
      ),
      bug_case(
        "string/replace-number-receiver-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace 121 "1" "x")|,
        "GAP-S139",
        "Clojure stringifies numeric replace receivers; PTC-Lisp currently raises a type error."
      ),
      bug_case(
        "string/split-string-delimiter-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a.b.c" ".")|,
        "GAP-S74",
        "Clojure string/split requires a regex Pattern delimiter; PTC-Lisp currently accepts plain strings."
      ),
      bug_case(
        "string/includes-char-hit-bug-001",
        "clojure.string",
        ["includes?"],
        ~S|(clojure.string/includes? "abc" \a)|,
        "GAP-S116",
        "Clojure string/includes? rejects Character substrings; PTC-Lisp currently treats them as one-character strings."
      ),
      bug_case(
        "string/includes-char-miss-bug-001",
        "clojure.string",
        ["includes?"],
        ~S|(clojure.string/includes? "abc" \z)|,
        "GAP-S116",
        "Clojure string/includes? rejects Character substrings even when absent; PTC-Lisp currently returns false."
      ),
      bug_case(
        "string/starts-with-char-hit-bug-001",
        "clojure.string",
        ["starts-with?"],
        ~S|(clojure.string/starts-with? "abc" \a)|,
        "GAP-S116",
        "Clojure string/starts-with? rejects Character prefixes; PTC-Lisp currently treats them as one-character strings."
      ),
      bug_case(
        "string/starts-with-char-miss-bug-001",
        "clojure.string",
        ["starts-with?"],
        ~S|(clojure.string/starts-with? "abc" \b)|,
        "GAP-S116",
        "Clojure string/starts-with? rejects Character prefixes even when absent; PTC-Lisp currently returns false."
      ),
      bug_case(
        "string/ends-with-char-hit-bug-001",
        "clojure.string",
        ["ends-with?"],
        ~S|(clojure.string/ends-with? "abc" \c)|,
        "GAP-S116",
        "Clojure string/ends-with? rejects Character suffixes; PTC-Lisp currently treats them as one-character strings."
      ),
      bug_case(
        "string/ends-with-char-miss-bug-001",
        "clojure.string",
        ["ends-with?"],
        ~S|(clojure.string/ends-with? "abc" \b)|,
        "GAP-S116",
        "Clojure string/ends-with? rejects Character suffixes even when absent; PTC-Lisp currently returns false."
      ),
      bug_case(
        "string/replace-char-match-string-replacement-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "aba" \a "x")|,
        "GAP-S116",
        "Clojure string/replace rejects Character match values with string replacements; PTC-Lisp currently replaces them."
      ),
      bug_case(
        "string/replace-string-match-char-replacement-bug-001",
        "clojure.string",
        ["replace"],
        ~S|(clojure.string/replace "aba" "a" \x)|,
        "GAP-S116",
        "Clojure string/replace rejects Character replacements for string matches; PTC-Lisp currently treats them as strings."
      ),
      bug_case(
        "string/split-char-delimiter-bug-001",
        "clojure.string",
        ["split"],
        ~S|(clojure.string/split "a,b" \,)|,
        "GAP-S116",
        "Clojure string/split requires a regex Pattern delimiter; PTC-Lisp currently accepts Character delimiters."
      ),
      bug_case(
        "string/blank-char-bug-001",
        "clojure.string",
        ["blank?"],
        ~S|(clojure.string/blank? \space)|,
        "GAP-S116",
        "Clojure string/blank? rejects Character inputs; PTC-Lisp currently treats them as one-character strings."
      ),
      bug_case(
        "string/trim-newline-char-bug-001",
        "clojure.string",
        ["trim-newline"],
        ~S|(clojure.string/trim-newline \newline)|,
        "GAP-S116",
        "Clojure string/trim-newline rejects Character inputs; PTC-Lisp currently treats them as one-character strings."
      ),
      bug_case(
        "string/index-of-float-from-index-bug-001",
        "clojure.string",
        ["index-of"],
        ~S|(clojure.string/index-of "abc" "b" 1.0)|,
        "GAP-S124",
        "Clojure string/index-of coerces finite numeric from-index arguments; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "string/last-index-of-float-from-index-bug-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "ababa" "a" 3.0)|,
        "GAP-S124",
        "Clojure string/last-index-of coerces finite numeric from-index arguments; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "string/blank-nbsp-bug-001",
        "clojure.string",
        ["blank?"],
        "(clojure.string/blank? \"\u00A0\")",
        "GAP-S50",
        "Clojure blank? does not treat non-breaking space as blank; PTC-Lisp currently does."
      ),
      bug_case(
        "string/blank-em-space-bug-001",
        "clojure.string",
        ["blank?"],
        ~S|(clojure.string/blank? "\u2003")|,
        "GAP-S50",
        "Clojure blank? treats EM SPACE as blank; PTC-Lisp currently does not."
      ),
      bug_case(
        "string/trim-nbsp-bug-001",
        "clojure.string",
        ["trim"],
        "(clojure.string/trim \"\u00A0x\u00A0\")",
        "GAP-S50",
        "Clojure trim does not remove non-breaking space; PTC-Lisp currently does."
      ),
      bug_case(
        "string/trim-em-space-bug-001",
        "clojure.string",
        ["trim"],
        ~S|(clojure.string/trim "\u2003x\u2003")|,
        "GAP-S50",
        "Clojure trim removes EM SPACE; PTC-Lisp currently leaves it unchanged."
      ),
      bug_case(
        "string/triml-nbsp-bug-001",
        "clojure.string",
        ["triml"],
        "(clojure.string/triml \"\u00A0x\")",
        "GAP-S50",
        "Clojure triml does not remove non-breaking space; PTC-Lisp currently does."
      ),
      bug_case(
        "string/triml-em-space-bug-001",
        "clojure.string",
        ["triml"],
        ~S|(clojure.string/triml "\u2003x")|,
        "GAP-S50",
        "Clojure triml removes leading EM SPACE; PTC-Lisp currently leaves it unchanged."
      ),
      bug_case(
        "string/trimr-nbsp-bug-001",
        "clojure.string",
        ["trimr"],
        "(clojure.string/trimr \"x\u00A0\")",
        "GAP-S50",
        "Clojure trimr does not remove non-breaking space; PTC-Lisp currently does."
      ),
      bug_case(
        "string/trimr-em-space-bug-001",
        "clojure.string",
        ["trimr"],
        ~S|(clojure.string/trimr "x\u2003")|,
        "GAP-S50",
        "Clojure trimr removes trailing EM SPACE; PTC-Lisp currently leaves it unchanged."
      ),
      bug_case(
        "string/split-lines-empty-bug-001",
        "clojure.string",
        ["split-lines"],
        ~S|(clojure.string/split-lines "")|,
        "GAP-S51",
        "Clojure split-lines returns one empty string for empty input; PTC-Lisp currently returns an empty vector."
      ),
      c(
        "string/split-lines-001",
        "clojure.string",
        ["split-lines"],
        ~S|(clojure.string/split-lines "a\nb")|,
        [
          :string
        ]
      ),
      c(
        "string/starts-001",
        "clojure.string",
        ["starts-with?"],
        ~S|(clojure.string/starts-with? "abc" "a")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/starts-with-number-bug-001",
        "clojure.string",
        ["starts-with?"],
        ~S|(clojure.string/starts-with? 123 "1")|,
        "GAP-S139",
        "Clojure stringifies numeric starts-with? receivers; PTC-Lisp currently raises a type error."
      ),
      c(
        "string/ends-001",
        "clojure.string",
        ["ends-with?"],
        ~S|(clojure.string/ends-with? "abc" "c")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/ends-with-number-bug-001",
        "clojure.string",
        ["ends-with?"],
        ~S|(clojure.string/ends-with? 123 "3")|,
        "GAP-S139",
        "Clojure stringifies numeric ends-with? receivers; PTC-Lisp currently raises a type error."
      ),
      c("string/trim-001", "clojure.string", ["trim"], ~S|(clojure.string/trim " abc ")|, [
        :string
      ]),
      c(
        "string/last-index-of-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "ababa" "ba")|,
        [:string]
      ),
      bug_case(
        "string/last-index-of-number-bug-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of 123 "2")|,
        "GAP-S139",
        "Clojure stringifies numeric last-index-of receivers; PTC-Lisp currently raises a type error."
      ),
      c(
        "string/trim-newline-001",
        "clojure.string",
        ["trim-newline"],
        ~S|(clojure.string/trim-newline "abc\n")|,
        [:string]
      ),
      c("string/triml-001", "clojure.string", ["triml"], ~S|(clojure.string/triml " abc ")|, [
        :string
      ]),
      c("string/trimr-001", "clojure.string", ["trimr"], ~S|(clojure.string/trimr " abc ")|, [
        :string
      ]),
      c(
        "string/upper-001",
        "clojure.string",
        ["upper-case"],
        ~S|(clojure.string/upper-case "abc")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/upper-case-number-bug-001",
        "clojure.string",
        ["upper-case"],
        "(clojure.string/upper-case 12)",
        "GAP-S139",
        "Clojure stringifies numeric upper-case input; PTC-Lisp currently raises a type error."
      ),
      c(
        "string/index-001",
        "clojure.string",
        ["index-of"],
        ~S|(clojure.string/index-of "abc" "b")|,
        [
          :string
        ]
      ),
      bug_case(
        "string/index-of-number-bug-001",
        "clojure.string",
        ["index-of"],
        ~S|(clojure.string/index-of 123 "2")|,
        "GAP-S139",
        "Clojure stringifies numeric index-of receivers; PTC-Lisp currently raises a type error."
      )
    ]
  end

  defp set_walk_cases do
    [
      c("set/union-001", "clojure.set", ["union"], ~S|(clojure.set/union #{1 2} #{2 3})|, [
        :collection
      ]),
      c(
        "set/intersection-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection #{1 2} #{2 3})|,
        [
          :collection
        ]
      ),
      c(
        "set/difference-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference #{1 2 3} #{2})|,
        [
          :collection
        ]
      ),
      c(
        "walk/prewalk-001",
        "clojure.walk",
        ["prewalk"],
        "(clojure.walk/prewalk identity [1 [2]])",
        [
          :collection
        ]
      ),
      c(
        "walk/postwalk-001",
        "clojure.walk",
        ["postwalk"],
        "(clojure.walk/postwalk identity [1 [2]])",
        [
          :collection
        ]
      ),
      c(
        "walk/walk-001",
        "clojure.walk",
        ["walk"],
        "(clojure.walk/walk identity identity [1 2])",
        [
          :collection
        ]
      )
    ]
  end

  defp core_predicate_numeric_cases do
    [
      {"core/abs-001", "abs", "(abs -3)", [:numeric]},
      {"core/mul-prime-001", "*'", "(*' 2 3)", [:numeric]},
      {"core/add-prime-001", "+'", "(+' 1 2)", [:numeric]},
      {"core/sub-prime-001", "-'", "(-' 5 2)", [:numeric]},
      {"core/lte-001", "<=", "(<= 1 1 2)", [:numeric]},
      {"core/gt-001", ">", "(> 3 2 1)", [:numeric]},
      {"core/numeric-equality-001", "==", "(== 1 1.0)", [:numeric]},
      {"core/compare-001", "compare", "(compare 1 2)", [:numeric]},
      {"core/even-predicate-001", "even?", "(even? 4)", [:numeric]},
      {"core/boolean-001", "boolean", "(boolean nil)", [:truthiness]},
      {"core/boolean-002", "boolean", "(boolean 0)", [:truthiness]},
      {"core/boolean-predicate-001", "boolean?", "(boolean? false)", [:truthiness]},
      {"core/char-predicate-001", "char?", "(char? \\a)", []},
      {"core/coll-predicate-001", "coll?", "(coll? [1])", [:collection]},
      {"core/counted-predicate-001", "counted?", "(counted? [1])", [:collection]},
      {"core/double-001", "double", "(double 1)", [:numeric]},
      {"core/double-predicate-001", "double?", "(double? 1.0)", [:numeric]},
      {"core/float-001", "float", "(float 1)", [:numeric]},
      {"core/float-predicate-001", "float?", "(float? 1.0)", [:numeric]},
      {"core/false-predicate-001", "false?", "(false? false)", [:truthiness]},
      {"core/fn-predicate-001", "fn?", "(fn? (fn [x] x))", []},
      {"core/ifn-predicate-001", "ifn?", "(ifn? :a)", []},
      {"core/indexed-predicate-001", "indexed?", "(indexed? [1])", [:collection]},
      {"core/infinite-predicate-001", "infinite?", "(infinite? ##Inf)", [:numeric]},
      {"core/nan-predicate-001", "NaN?", "(NaN? ##NaN)", [:numeric]},
      {"core/int-001", "int", "(int 1.9)", [:numeric]},
      {"core/int-predicate-001", "int?", "(int? 1)", [:numeric]},
      {"core/integer-predicate-001", "integer?", "(integer? 1)", [:numeric]},
      {"core/nat-int-predicate-001", "nat-int?", "(nat-int? 0)", [:numeric]},
      {"core/neg-int-predicate-001", "neg-int?", "(neg-int? -1)", [:numeric]},
      {"core/pos-int-predicate-001", "pos-int?", "(pos-int? 1)", [:numeric]},
      {"core/neg-predicate-001", "neg?", "(neg? -1)", [:numeric]},
      {"core/pos-predicate-001", "pos?", "(pos? 1)", [:numeric]},
      {"core/zero-predicate-001", "zero?", "(zero? 0)", [:numeric]},
      {"core/true-predicate-001", "true?", "(true? true)", [:truthiness]},
      {"core/seq-predicate-001", "seq?", "(seq? (seq [1]))", [:collection]},
      {"core/seqable-predicate-001", "seqable?", "(seqable? nil)", [:collection]},
      {"core/sequential-predicate-001", "sequential?", "(sequential? [1])", [:collection]},
      {"core/map-predicate-001", "map?", "(map? {:a 1})", [:collection]},
      {"core/set-predicate-001", "set?", ~S|(set? #{1})|, [:collection]},
      {"core/vector-predicate-001", "vector?", "(vector? [1])", [:collection]},
      {"core/sorted-predicate-001", "sorted?", "(sorted? [1 2])", [:collection]},
      {"core/reversible-predicate-001", "reversible?", "(reversible? [1])", [:collection]},
      {"core/map-entry-predicate-001", "map-entry?", "(map-entry? [:a 1])", [:collection]},
      {"core/associative-predicate-001", "associative?", "(associative? {:a 1})", [:collection]},
      {"core/keyword-predicate-001", "keyword?", "(keyword? :a)", []},
      {"core/odd-predicate-001", "odd?", "(odd? 3)", [:numeric]},
      {"core/rational-predicate-001", "rational?", "(rational? 1)", [:numeric]},
      {"core/bit-and-001", "bit-and", "(bit-and 6 3)", [:numeric]},
      {"core/bit-or-001", "bit-or", "(bit-or 4 1)", [:numeric]},
      {"core/bit-xor-001", "bit-xor", "(bit-xor 6 3)", [:numeric]},
      {"core/bit-not-001", "bit-not", "(bit-not 0)", [:numeric]},
      {"core/bit-shift-left-001", "bit-shift-left", "(bit-shift-left 1 3)", [:numeric]},
      {"core/bit-shift-right-001", "bit-shift-right", "(bit-shift-right 8 1)", [:numeric]},
      {"core/bit-clear-001", "bit-clear", "(bit-clear 7 1)", [:numeric]},
      {"core/bit-set-001", "bit-set", "(bit-set 4 1)", [:numeric]},
      {"core/bit-flip-001", "bit-flip", "(bit-flip 4 2)", [:numeric]},
      {"core/bit-test-001", "bit-test", "(bit-test 4 2)", [:numeric]},
      {"core/bit-and-not-001", "bit-and-not", "(bit-and-not 7 2)", [:numeric]}
    ]
    |> Enum.map(fn {id, var, form, tags} -> c(id, "clojure.core", [var], form, tags) end)
  end

  defp core_sequence_map_cases do
    [
      {"core/array-map-001", "array-map", "(array-map :a 1 :b 2)", [:collection]},
      {"core/hash-map-001", "hash-map", "(hash-map :a 1 :b 2)", [:collection]},
      {"core/hash-set-001", "hash-set", "(hash-set 1 2 1)", [:collection]},
      {"core/count-001", "count", "(count [1 2 3])", [:collection]},
      {"core/empty-predicate-001", "empty?", "(empty? [])", [:collection]},
      {"core/not-empty-001", "not-empty", "(not-empty [])", [:collection]},
      {"core/peek-001", "peek", "(peek [1 2])", [:collection]},
      {"core/second-001", "second", "(second [1 2])", [:collection]},
      {"core/last-001", "last", "(last [1 2 3])", [:collection]},
      {"core/cons-001", "cons", "(cons 1 [2 3])", [:collection]},
      {"core/concat-001", "concat", "(concat [1] [2 3])", [:collection]},
      {"core/butlast-001", "butlast", "(butlast [1 2 3])", [:collection]},
      {"core/ffirst-001", "ffirst", "(ffirst [[1 2] [3 4]])", [:collection]},
      {"core/fnext-001", "fnext", "(fnext [1 2 3])", [:collection]},
      {"core/nfirst-001", "nfirst", "(nfirst [[1 2] [3 4]])", [:collection]},
      {"core/nnext-001", "nnext", "(nnext [1 2 3])", [:collection]},
      {"core/nthnext-001", "nthnext", "(nthnext [1 2 3 4] 2)", [:collection]},
      {"core/nthrest-001", "nthrest", "(nthrest [1 2 3 4] 2)", [:collection]},
      {"core/drop-001", "drop", "(drop 2 [1 2 3])", [:collection]},
      {"core/take-001", "take", "(take 2 [1 2 3])", [:collection]},
      {"core/drop-last-001", "drop-last", "(drop-last 2 [1 2 3 4])", [:collection]},
      {"core/drop-while-001", "drop-while", "(drop-while odd? [1 3 4])", [:collection]},
      {"core/take-last-001", "take-last", "(take-last 2 [1 2 3])", [:collection]},
      {"core/take-while-001", "take-while", "(take-while odd? [1 3 4])", [:collection]},
      {"core/split-at-001", "split-at", "(split-at 2 [1 2 3 4])", [:collection]},
      {"core/split-with-001", "split-with", "(split-with odd? [1 3 4])", [:collection]},
      {"core/distinct-001", "distinct", "(distinct [1 1 2 1])", [:collection]},
      {"core/distinct-predicate-001", "distinct?", "(distinct? 1 2 1)", []},
      {"core/dedupe-001", "dedupe", "(dedupe [1 1 2 1])", [:collection]},
      {"core/flatten-001", "flatten", "(flatten [1 [2 [3]]])", [:collection]},
      {"core/interleave-001", "interleave", "(interleave [1 2] [:a :b])", [:collection]},
      {"core/interleave-zero-001", "interleave", "(interleave)", [:collection]},
      {"core/interleave-three-001", "interleave", "(interleave [1 2] [3 4] [5 6])",
       [:collection]},
      {"core/interpose-001", "interpose", ~S|(interpose "," ["a" "b" "c"])|, [:collection]},
      {"core/partition-001", "partition", "(partition 2 [1 2 3 4])", [:collection]},
      {"core/partition-all-001", "partition-all", "(partition-all 2 [1 2 3])", [:collection]},
      {"core/partition-by-001", "partition-by", "(partition-by odd? [1 3 2 4 5])", [:collection]},
      {"core/mapcat-001", "mapcat", "(mapcat reverse [[1 2] [3 4]])", [:collection]},
      {"core/map-indexed-001", "map-indexed", "(map-indexed vector [:a :b])", [:collection]},
      {"core/keep-indexed-001", "keep-indexed",
       "(keep-indexed (fn [i x] (when (odd? i) x)) [:a :b :c])", [:collection]},
      {"core/filterv-001", "filterv", "(filterv odd? [1 2 3])", [:collection]},
      {"core/mapv-001", "mapv", "(mapv inc [1 2 3])", [:collection]},
      {"core/remove-001", "remove", "(remove odd? [1 2 3])", [:collection]},
      {"core/reverse-001", "reverse", "(reverse [1 2 3])", [:collection]},
      {"core/sort-001", "sort", "(sort [3 1 2])", [:collection]},
      {"core/sort-by-001", "sort-by", ~S|(sort-by count ["aaa" "b" "cc"])|, [:collection]},
      {"core/vec-001", "vec", "(vec (list 1 2 3))", [:collection]},
      {"core/set-001", "set", "(set [1 2 1])", [:collection]},
      {"core/select-keys-001", "select-keys", "(select-keys {:a 1 :b 2} [:a])", [:collection]},
      {"core/disj-001", "disj", ~S|(disj #{1 2 3} 2)|, [:collection]},
      {"core/dissoc-001", "dissoc", "(dissoc {:a 1 :b 2} :a)", [:collection]},
      {"core/keys-001", "keys", "(keys {:a 1 :b 2})", [:collection]},
      {"core/vals-001", "vals", "(vals {:a 1 :b 2})", [:collection]},
      {"core/merge-001", "merge", "(merge {:a 1} {:b 2})", [:collection]},
      {"core/merge-with-001", "merge-with", "(merge-with + {:a 1} {:a 2})", [:collection]},
      {"core/update-keys-001", "update-keys", "(update-keys {:a 1} name)", [:collection]},
      {"core/update-vals-001", "update-vals", "(update-vals {:a 1} inc)", [:collection]},
      {"core/update-in-001", "update-in", "(update-in {:a {:b 1}} [:a :b] inc)", [:collection]},
      {"core/reduce-kv-001", "reduce-kv", "(reduce-kv (fn [acc k v] (conj acc [k v])) [] {:a 1})",
       [:collection]},
      {"core/frequencies-001", "frequencies", "(frequencies [:a :b :a])", [:collection]},
      {"core/group-by-001", "group-by", "(group-by odd? [1 2 3])", [:collection]},
      {"core/zipmap-001", "zipmap", "(zipmap [:a :b] [1 2])", [:collection]},
      {"core/tree-seq-001", "tree-seq", "(take 4 (tree-seq sequential? seq [1 [2 3]]))",
       [:collection]}
    ]
    |> Enum.map(fn {id, var, form, tags} -> c(id, "clojure.core", [var], form, tags) end)
  end

  defp core_hof_control_cases do
    [
      {"core/comp-001", "comp", "((comp inc inc) 1)", []},
      {"core/complement-001", "complement", "((complement odd?) 2)", []},
      {"core/constantly-001", "constantly", "((constantly :x) 1 2)", []},
      {"core/partial-001", "partial", "((partial + 1) 2 3)", []},
      {"core/juxt-001", "juxt", "((juxt inc dec) 2)", []},
      {"core/fnil-001", "fnil", "((fnil + 0) nil 2)", []},
      {"core/every-pred-001", "every-pred", "((every-pred odd? pos?) 1 3)", []},
      {"core/some-fn-001", "some-fn", "((some-fn :a :b) {:b 2})", []},
      {"core/every-001", "every?", "(every? odd? [1 3])", [:collection]},
      {"core/some-001", "some", "(some even? [1 3 4])", [:collection]},
      {"core/not-any-001", "not-any?", "(not-any? even? [1 3])", [:collection]},
      {"core/not-every-001", "not-every?", "(not-every? odd? [1 3 4])", [:collection]},
      {"core/not-001", "not", "(not nil)", [:truthiness]},
      {"core/not-eq-001", "not=", "(not= 1 2)", []},
      {"core/identity-001", "identity", "(identity :x)", []},
      {"core/inc-001", "inc", "(inc 1)", [:numeric]},
      {"core/inc-prime-001", "inc'", "(inc' 1)", [:numeric]},
      {"core/dec-001", "dec", "(dec 1)", [:numeric]},
      {"core/dec-prime-001", "dec'", "(dec' 1)", [:numeric]},
      {"core/max-001", "max", "(max 1 3 2)", [:numeric]},
      {"core/min-001", "min", "(min 1 3 2)", [:numeric]},
      {"core/max-key-001", "max-key", ~S|(max-key count "a" "abc" "ab")|, []},
      {"core/min-key-001", "min-key", ~S|(min-key count "a" "abc" "ab")|, []},
      {"core/mod-001", "mod", "(mod -3 2)", [:numeric]},
      {"core/quot-001", "quot", "(quot -3 2)", [:numeric]},
      {"core/rem-001", "rem", "(rem -3 2)", [:numeric]},
      {"core/parse-long-001", "parse-long", ~S|(parse-long "42")|, [:numeric]},
      {"core/parse-double-001", "parse-double", ~S|(parse-double "1.5")|, [:numeric]},
      {"core/parse-boolean-001", "parse-boolean", ~S|(parse-boolean "true")|, []},
      {"core/keyword-001", "keyword", ~S|(keyword "abc")|, []},
      {"core/name-001", "name", "(name :abc)", []},
      {"core/pr-str-001", "pr-str", "(pr-str {:a 1})", [:string]},
      {"core/str-001", "str", ~S|(str "a" 1 :b)|, [:string]},
      {"core/re-matches-001", "re-matches", ~S|(re-matches #"\d+" "123")|, [:string]},
      {"core/re-pattern-001", "re-pattern", ~S|(re-find (re-pattern "\\d+") "a12")|, [:string]},
      {"core/re-seq-001", "re-seq", ~S|(re-seq #"\d+" "a1b22")|, [:string]},
      {"core/format-001", "format", ~S|(format "%s %d" "x" 1)|, [:string]},
      {"core/println-001", "println", ~S|(println "x")|, []},
      {"core/def-001", "def", "(do (def x 1) x)", []},
      {"core/do-001", "do", "(do 1 2 3)", []},
      {"core/defonce-001", "defonce", "(do (defonce y 1) (defonce y 2) y)", []},
      {"core/cond-thread-001", "cond->", "(cond-> {:a 1} true (assoc :b 2) false (assoc :c 3))",
       []},
      {"core/cond-thread-last-001", "cond->>",
       "(cond->> [1 2 3] true (map inc) false (filter odd?))", []},
      {"core/as-thread-001", "as->", "(as-> 1 x (+ x 2) (* x 3))", []},
      {"core/if-not-001", "if-not", "(if-not nil :yes :no)", [:truthiness]},
      {"core/if-let-001", "if-let", "(if-let [x 1] x :no)", [:truthiness]},
      {"core/if-some-001", "if-some", "(if-some [x false] :yes :no)", [:truthiness]},
      {"core/when-not-001", "when-not", "(when-not false :yes)", [:truthiness]},
      {"core/when-let-001", "when-let", "(when-let [x 1] x)", [:truthiness]},
      {"core/when-first-001", "when-first", "(when-first [x [1 2]] x)", [:collection]},
      {"core/when-some-001", "when-some", "(when-some [x false] :yes)", [:truthiness]},
      {"core/for-001", "for", "(for [x [1 2]] (inc x))", [:collection]},
      {"core/loop-001", "loop",
       "(loop [i 0 acc []] (if (< i 3) (recur (inc i) (conj acc i)) acc))", []},
      {"core/recur-001", "recur", "(loop [i 0] (if (< i 2) (recur (inc i)) i))", []},
      {"core/doseq-println-001", "doseq", ~S|(doseq [x [1 2]] (println x))|, []},
      {"core/pcalls-001", "pcalls", "(pcalls (fn [] 1) (fn [] 2))", []},
      {"core/thread-pcalls-001", "pcalls", "(-> (fn [] 1) (pcalls))", []},
      {"core/pmap-001", "pmap", "(pmap inc [1 2])", [:collection]},
      {"core/thread-last-pmap-001", "pmap", "(->> [1 2 3] (pmap inc))", [:collection]},
      {"core/thread-shadowed-pmap-001", "pmap",
       "(let [pmap (fn [f xs] [:shadow (f (first xs))])] (->> [1] (pmap inc)))", []},
      {"core/thread-last-apply-001", "apply", "(->> [[1 2] [3 4]] (apply concat))",
       [
         :collection
       ]},
      {"core/some-thread-001", "some->", "(some-> {:a 1} :a inc)", []},
      {"core/some-thread-last-001", "some->>", "(some->> [1 2 3] (map inc) (filter odd?))", []},
      {"core/condp-001", "condp", "(condp = 2 1 :one 2 :two :other)", []}
    ]
    |> Enum.map(fn {id, var, form, tags} -> c(id, "clojure.core", [var], form, tags) end)
  end

  defp historical_regression_cases do
    [
      regression_case(
        "regression/gap-s01-and-value-001",
        "clojure.core",
        ["and"],
        "(and 1 2 :ok)",
        ["GAP-S01"],
        [:truthiness]
      ),
      regression_case(
        "regression/gap-s01-or-value-001",
        "clojure.core",
        ["or"],
        "(or nil false :ok)",
        ["GAP-S01"],
        [:truthiness]
      ),
      regression_case(
        "regression/gap-s02-short-fn-call-001",
        "clojure.core",
        ["#()"],
        "(do (defn foo [] 1) (#(foo)))",
        ["GAP-S02"],
        []
      ),
      regression_case(
        "regression/gap-s03-defn-inside-let-001",
        "clojure.core",
        ["defn", "let"],
        "(do (let [] (defn f [] 1)) (f))",
        ["GAP-S03"],
        []
      ),
      regression_case(
        "regression/gap-f01-named-fn-001",
        "clojure.core",
        ["fn"],
        "((fn fact [n] (if (zero? n) 1 (* n (fact (dec n))))) 5)",
        ["GAP-F01"],
        []
      ),
      regression_case(
        "regression/gap-f02-rest-destructuring-001",
        "clojure.core",
        ["fn"],
        "((fn [& [y]] y) 1)",
        ["GAP-F02"],
        [:destructuring]
      ),
      regression_case(
        "regression/gap-c01-int-predicate-001",
        "clojure.core",
        ["int?"],
        "(int? 1)",
        ["GAP-C01"],
        [:numeric]
      ),
      regression_case(
        "regression/gap-c02-comment-001",
        "clojure.core",
        ["comment"],
        ~S|(comment (fail "x"))|,
        ["GAP-C02"],
        []
      ),
      regression_case(
        "regression/gap-c03-short-fn-rest-001",
        "clojure.core",
        ["#()"],
        "(#(vector %1 %&) 1 2 3)",
        ["GAP-C03"],
        []
      ),
      regression_case(
        "regression/gap-c04-strs-destructuring-001",
        "clojure.core",
        ["fn"],
        ~S|((fn [{:strs [a]}] a) {"a" 1})|,
        ["GAP-C04"],
        [:destructuring]
      ),
      regression_case(
        "regression/gap-s04-assoc-many-001",
        "clojure.core",
        ["assoc"],
        "(assoc {} :a 1 :b 2 :c 3)",
        ["GAP-S04"],
        [:collection]
      ),
      regression_case(
        "regression/gap-s06-shadow-fn-param-001",
        "clojure.core",
        ["defn", "fn"],
        "(do (defn foo [fn] (fn 1)) (foo inc))",
        ["GAP-S06"],
        []
      ),
      regression_case(
        "regression/gap-s07-rest-kwargs-001",
        "clojure.core",
        ["defn"],
        "(do (defn f [& {:keys [a]}] a) (f :a 1))",
        ["GAP-S07"],
        [:destructuring]
      ),
      div_case(
        "regression/gap-s08-even-float-001",
        "clojure.core",
        ["even?"],
        "(even? 4.0)",
        "GAP-S08",
        true,
        "PTC-Lisp accepts whole-number floats for even? instead of raising."
      ),
      div_case(
        "regression/gap-s08-odd-float-001",
        "clojure.core",
        ["odd?"],
        "(odd? 4.5)",
        "GAP-S08",
        false,
        "PTC-Lisp returns false for non-whole floats instead of raising."
      ),
      regression_case(
        "regression/div-17-nested-short-fn-001",
        "clojure.core",
        ["#()"],
        "#(map #(+ % 1) %&)",
        ["DIV-17"],
        []
      ),
      regression_case(
        "regression/div-20-decimal-false-001",
        "clojure.core",
        ["decimal?"],
        "(decimal? 1.0)",
        ["DIV-20"],
        [:numeric]
      ),
      regression_case(
        "regression/div-20-ratio-false-001",
        "clojure.core",
        ["ratio?"],
        "(ratio? 1)",
        ["DIV-20"],
        [:numeric]
      ),
      regression_case(
        "regression/gap-s132-pmap-nil-001",
        "clojure.core",
        ["pmap"],
        "(pmap inc nil)",
        ["GAP-S132"],
        [:parallel]
      ),
      regression_case(
        "regression/gap-s132-pmap-string-001",
        "clojure.core",
        ["pmap"],
        ~S|(pmap str "ab")|,
        ["GAP-S132"],
        [:parallel]
      ),
      regression_case(
        "regression/gap-s132-pmap-multi-coll-001",
        "clojure.core",
        ["pmap"],
        "(pmap + [1 2] [3 4])",
        ["GAP-S132"],
        [:parallel]
      ),
      regression_case(
        "regression/gap-s132-pmap-multi-coll-truncate-001",
        "clojure.core",
        ["pmap"],
        "(pmap + [1 2 3] [10 20])",
        ["GAP-S132"],
        [:parallel]
      )
    ]
  end

  defp core_bug_cases do
    [
      bug_case(
        "core/nth-negative-bug-001",
        "clojure.core",
        ["nth"],
        "(nth [1 2] -1)",
        "GAP-S10",
        "Negative nth indexes currently read from the end; they should not silently return data."
      ),
      regression_case(
        "core/nth-default-001",
        "clojure.core",
        ["nth"],
        "(nth [1 2] 5 :x)",
        ["GAP-S11"],
        [:collection]
      ),
      regression_case(
        "core/nth-negative-default-001",
        "clojure.core",
        ["nth"],
        "(nth [1 2] -1 :x)",
        ["GAP-S11"],
        [:collection]
      ),
      regression_case(
        "core/nth-nil-default-001",
        "clojure.core",
        ["nth"],
        "(nth nil 0 :x)",
        ["GAP-S11"],
        [:collection]
      ),
      regression_case(
        "core/nth-string-default-001",
        "clojure.core",
        ["nth"],
        ~S|(nth "a" 1 :missing)|,
        ["GAP-S11"],
        [:collection]
      ),
      regression_case(
        "core/nth-nil-001",
        "clojure.core",
        ["nth"],
        "(nth nil 0)",
        ["GAP-S94"],
        [:collection]
      ),
      regression_case(
        "core/nth-nil-oob-001",
        "clojure.core",
        ["nth"],
        "(nth nil 5)",
        ["GAP-S94"],
        [:collection]
      ),
      bug_case(
        "core/get-string-index-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get "abc" 1)|,
        "GAP-S12",
        "Clojure get supports string indexes; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-string-index-default-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get "ab" 9 :x)|,
        "GAP-S12",
        "Clojure get supports string indexes and returns the default out of range; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-string-non-index-key-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get "abc" :a)|,
        "GAP-S12",
        "Clojure get returns nil for non-index string keys; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-string-index-bug-001",
        "clojure.core",
        ["get-in"],
        ~S|(get-in "ab" [0])|,
        "GAP-S12",
        "Clojure get-in supports string indexes through get semantics; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/vector-call-bug-001",
        "clojure.core",
        ["vector"],
        "([10 20] 1)",
        "GAP-S13",
        "Clojure vectors are callable by index; PTC-Lisp currently treats vectors as non-callable."
      ),
      bug_case(
        "core/apply-vector-function-bug-001",
        "clojure.core",
        ["apply"],
        "(apply [10 20] [1])",
        "GAP-S13",
        "Clojure apply accepts vectors as IFn lookup functions; PTC-Lisp currently rejects vector function position."
      ),
      bug_case(
        "core/ifn-vector-bug-001",
        "clojure.core",
        ["ifn?"],
        "(ifn? [1 2])",
        "GAP-S13",
        "Clojure vectors implement IFn; PTC-Lisp currently reports them as non-invokable."
      ),
      regression_case(
        "core/contains-nil-001",
        "clojure.core",
        ["contains?"],
        "(contains? nil :a)",
        ["GAP-S14"],
        [:collection]
      ),
      regression_case(
        "core/replace-seq-001",
        "clojure.core",
        ["replace"],
        "(replace {:a :x} [:a :b])",
        ["GAP-S16"],
        [:collection]
      ),
      regression_case(
        "core/replace-seq-vector-smap-001",
        "clojure.core",
        ["replace"],
        "(replace [10 20 30] [0 1 2 0])",
        ["GAP-S16"],
        [:collection]
      ),
      regression_case(
        "core/replace-seq-map-vals-001",
        "clojure.core",
        ["replace"],
        "(replace {2 :two} [1 2 3 2])",
        ["GAP-S16"],
        [:collection]
      ),
      regression_case(
        "core/replace-seq-nil-coll-001",
        "clojure.core",
        ["replace"],
        "(replace {} nil)",
        ["GAP-S16"],
        [:collection]
      ),
      bug_case(
        "core/key-vector-bug-001",
        "clojure.core",
        ["key"],
        "(key [:a 1])",
        "GAP-S17",
        "Clojure key requires a map entry; PTC-Lisp currently accepts a plain vector."
      ),
      bug_case(
        "core/val-vector-bug-001",
        "clojure.core",
        ["val"],
        "(val [:a 1])",
        "GAP-S17",
        "Clojure val requires a map entry; PTC-Lisp currently accepts a plain vector."
      ),
      bug_case(
        "core/key-list-pair-bug-001",
        "clojure.core",
        ["key"],
        "(key (list :a 1))",
        "GAP-S17",
        "Clojure key requires a map entry; PTC-Lisp list is a vector alias and currently accepts a list pair."
      ),
      bug_case(
        "core/val-list-pair-bug-001",
        "clojure.core",
        ["val"],
        "(val (list :a 1))",
        "GAP-S17",
        "Clojure val requires a map entry; PTC-Lisp list is a vector alias and currently accepts a list pair."
      ),
      bug_case(
        "core/map-entry-predicate-seq-map-bug-001",
        "clojure.core",
        ["map-entry?"],
        "(map-entry? (first (seq {:a 1})))",
        "GAP-S136",
        "Clojure map-entry? recognizes map entries from explicit seq map views; PTC-Lisp currently returns false."
      ),
      bug_case(
        "core/doseq-def-side-effect-bug-001",
        "clojure.core",
        ["doseq", "def"],
        "(do (def xs []) (doseq [x [1 2]] (def xs (conj xs x))) xs)",
        "GAP-S18",
        "doseq executes the body, but def side effects inside the body do not update the outer var."
      ),
      bug_case(
        "core/dissoc-nil-bug-001",
        "clojure.core",
        ["dissoc"],
        "(dissoc nil :a)",
        "GAP-S19",
        "Clojure map helpers accept nil as an empty map; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-nil-bug-001",
        "clojure.core",
        ["get-in"],
        "(get-in nil [:a])",
        "GAP-S19",
        "Clojure get-in returns nil from a nil root; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-nil-default-bug-001",
        "clojure.core",
        ["get-in"],
        "(get-in nil [:a] :x)",
        "GAP-S19",
        "Clojure get-in returns the default for nil roots; PTC-Lisp currently raises."
      ),
      regression_case(
        "core/get-in-nil-path-001",
        "clojure.core",
        ["get-in"],
        "(get-in {:a 1} nil)",
        ["GAP-S144"],
        [:collection]
      ),
      bug_case(
        "core/update-nil-bug-001",
        "clojure.core",
        ["update"],
        "(update nil :a (fnil inc 0))",
        "GAP-S19",
        "Clojure update can build a map from nil; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/update-vector-append-bug-001",
        "clojure.core",
        ["update"],
        "(update [10 20] 2 (fnil inc 0))",
        "GAP-S83",
        "Clojure update can append at a vector's count index via assoc semantics; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/update-in-vector-append-bug-001",
        "clojure.core",
        ["update-in"],
        "(update-in [10 20] [2] (fnil inc 0))",
        "GAP-S83",
        "Clojure update-in can append at a vector's count index via assoc semantics; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/update-in-empty-vector-append-bug-001",
        "clojure.core",
        ["update-in"],
        "(update-in [] [0] (fnil identity :x))",
        "GAP-S83",
        "Clojure update-in can append at an empty vector's count index; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/seq-predicate-vector-bug-001",
        "clojure.core",
        ["seq?"],
        "(seq? [1])",
        "GAP-S84",
        "Clojure seq? returns false for vectors; PTC-Lisp currently treats vectors as seq values."
      ),
      bug_case(
        "core/merge-zero-arity-bug-001",
        "clojure.core",
        ["merge"],
        "(merge)",
        "GAP-S54",
        "Clojure zero-arity merge returns nil; PTC-Lisp currently returns an empty map."
      ),
      bug_case(
        "core/merge-with-zero-maps-bug-001",
        "clojure.core",
        ["merge-with"],
        "(merge-with +)",
        "GAP-S54",
        "Clojure merge-with with no maps returns nil; PTC-Lisp currently returns an empty map."
      ),
      bug_case(
        "core/merge-single-nil-bug-001",
        "clojure.core",
        ["merge"],
        "(merge nil)",
        "GAP-S54",
        "Clojure merge with a single nil map returns nil; PTC-Lisp currently returns an empty map."
      ),
      bug_case(
        "core/merge-with-single-nil-bug-001",
        "clojure.core",
        ["merge-with"],
        "(merge-with + nil)",
        "GAP-S54",
        "Clojure merge-with with a single nil map returns nil; PTC-Lisp currently returns an empty map."
      ),
      regression_case(
        "core/merge-single-string-001",
        "clojure.core",
        ["merge"],
        ~S|(merge "ab")|,
        ["GAP-S146"],
        [:collection]
      ),
      regression_case(
        "core/merge-single-vector-001",
        "clojure.core",
        ["merge"],
        "(merge [1 2])",
        ["GAP-S146"],
        [:collection]
      ),
      regression_case(
        "core/merge-with-single-string-001",
        "clojure.core",
        ["merge-with"],
        ~S|(merge-with + "ab")|,
        ["GAP-S146"],
        [:collection]
      ),
      regression_case(
        "core/merge-with-single-vector-001",
        "clojure.core",
        ["merge-with"],
        "(merge-with + [1 2])",
        ["GAP-S146"],
        [:collection]
      ),
      bug_case(
        "core/merge-vector-target-bug-001",
        "clojure.core",
        ["merge"],
        "(merge [1 2] [3 4])",
        "GAP-S90",
        "Clojure merge can use a vector target and conjoin later collections; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/merge-with-vector-target-bug-001",
        "clojure.core",
        ["merge-with"],
        "(merge-with + [1 2] {1 10})",
        "GAP-S90",
        "Clojure merge-with can use a vector target and combine entries by index; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/merge-vector-entry-source-bug-001",
        "clojure.core",
        ["merge"],
        "(merge {:a 1} [:b 2])",
        "GAP-S100",
        "Clojure merge can conjoin a vector map entry source into a map target; PTC-Lisp currently requires every source to be a map."
      ),
      regression_case(
        "core/update-in-empty-path-001",
        "clojure.core",
        ["update-in"],
        "(update-in {:a 1} [] identity)",
        ["GAP-S55"],
        [:collection]
      ),
      regression_case(
        "core/update-in-empty-path-replace-001",
        "clojure.core",
        ["update-in"],
        "(update-in {:a 1} [] (constantly 2))",
        ["GAP-S55"],
        [:collection]
      ),
      regression_case(
        "core/update-in-nil-path-001",
        "clojure.core",
        ["update-in"],
        "(update-in {:a 1} nil identity)",
        ["GAP-S55"],
        [:collection]
      ),
      bug_case(
        "core/empty-string-bug-001",
        "clojure.core",
        ["empty"],
        ~S|(empty "abc")|,
        "GAP-S56",
        "Clojure empty returns nil for strings; PTC-Lisp currently returns an empty string."
      ),
      bug_case(
        "core/empty-number-bug-001",
        "clojure.core",
        ["empty"],
        "(empty 1)",
        "GAP-S88",
        "Clojure empty returns nil for non-collection values; PTC-Lisp currently raises for numbers."
      ),
      bug_case(
        "core/empty-boolean-bug-001",
        "clojure.core",
        ["empty"],
        "(empty true)",
        "GAP-S88",
        "Clojure empty returns nil for non-collection values; PTC-Lisp currently raises for booleans."
      ),
      bug_case(
        "core/empty-keyword-bug-001",
        "clojure.core",
        ["empty"],
        "(empty :a)",
        "GAP-S88",
        "Clojure empty returns nil for non-collection values; PTC-Lisp currently returns an empty map for keywords."
      ),
      bug_case(
        "core/empty-char-bug-001",
        "clojure.core",
        ["empty"],
        ~S|(empty \a)|,
        "GAP-S88",
        "Clojure empty returns nil for non-collection Character values; PTC-Lisp currently returns an empty string."
      ),
      bug_case(
        "core/concat-string-bug-001",
        "clojure.core",
        ["concat"],
        ~S|(concat "ab" "cd")|,
        "GAP-S57",
        "Clojure concat treats strings as seqable; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/juxt-multiple-args-bug-001",
        "clojure.core",
        ["juxt"],
        "((juxt + vector) 1 2 3)",
        "GAP-S58",
        "Clojure juxt forwards all call arguments to each function; PTC-Lisp currently supports only one argument."
      ),
      regression_case(
        "core/juxt-zero-arity-001",
        "clojure.core",
        ["juxt"],
        "(juxt)",
        ["GAP-S110"],
        [:hof]
      ),
      regression_case(
        "core/juxt-zero-arity-call-001",
        "clojure.core",
        ["juxt"],
        "((juxt) 1)",
        ["GAP-S110"],
        [:hof]
      ),
      bug_case(
        "core/parse-double-whitespace-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double " 1.5")|,
        "GAP-S61",
        "Clojure parse-double accepts surrounding whitespace; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/parse-double-leading-dot-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double ".5")|,
        "GAP-S61",
        "Clojure parse-double accepts Java decimal spellings with a leading decimal point; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/parse-double-trailing-dot-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double "1.")|,
        "GAP-S61",
        "Clojure parse-double accepts Java decimal spellings with a trailing decimal point; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/parse-double-trailing-whitespace-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double "1.5 ")|,
        "GAP-S61",
        "Clojure parse-double accepts trailing whitespace; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/parse-double-tab-whitespace-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double "\t1.5")|,
        "GAP-S61",
        "Clojure parse-double accepts tab whitespace; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/parse-double-hex-float-bug-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double "0x1.0p0")|,
        "GAP-S61",
        "Clojure parse-double accepts Java hexadecimal floating-point syntax; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/float-infinity-bug-001",
        "clojure.core",
        ["float"],
        "(float ##Inf)",
        "GAP-S122",
        "Clojure float coercion rejects positive infinity as out of range; PTC-Lisp currently returns infinity."
      ),
      bug_case(
        "core/float-negative-infinity-bug-001",
        "clojure.core",
        ["float"],
        "(float ##-Inf)",
        "GAP-S122",
        "Clojure float coercion rejects negative infinity as out of range; PTC-Lisp currently returns negative infinity."
      ),
      bug_case(
        "core/double-predicate-nan-bug-001",
        "clojure.core",
        ["double?"],
        "(double? ##NaN)",
        "GAP-S127",
        "Clojure double? returns true for NaN literals; PTC-Lisp currently returns false."
      ),
      bug_case(
        "core/double-predicate-infinity-bug-001",
        "clojure.core",
        ["double?"],
        "(double? ##Inf)",
        "GAP-S127",
        "Clojure double? returns true for infinite literals; PTC-Lisp currently returns false."
      ),
      bug_case(
        "core/float-predicate-nan-bug-001",
        "clojure.core",
        ["float?"],
        "(float? ##NaN)",
        "GAP-S127",
        "Clojure float? returns true for NaN literals; PTC-Lisp currently returns false."
      ),
      bug_case(
        "core/float-predicate-infinity-bug-001",
        "clojure.core",
        ["float?"],
        "(float? ##Inf)",
        "GAP-S127",
        "Clojure float? returns true for infinite literals; PTC-Lisp currently returns false."
      ),
      bug_case(
        "core/parse-long-overflow-bug-001",
        "clojure.core",
        ["parse-long"],
        ~S|(parse-long "9223372036854775808")|,
        "GAP-S85",
        "Clojure parse-long returns nil for values outside the Java long range; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "core/parse-long-underflow-bug-001",
        "clojure.core",
        ["parse-long"],
        ~S|(parse-long "-9223372036854775809")|,
        "GAP-S85",
        "Clojure parse-long returns nil for values below the Java long range; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "core/parse-long-plus-overflow-bug-001",
        "clojure.core",
        ["parse-long"],
        ~S|(parse-long "+9223372036854775808")|,
        "GAP-S85",
        "Clojure parse-long returns nil for signed values outside the Java long range; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "core/int-nan-bug-001",
        "clojure.core",
        ["int"],
        "(int ##NaN)",
        "GAP-S62",
        "Clojure int coercion returns 0 for NaN; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/int-overflow-positive-bug-001",
        "clojure.core",
        ["int"],
        "(int 2147483648)",
        "GAP-S111",
        "Clojure int coercion raises on values outside the Java int range; PTC-Lisp currently returns the arbitrary-precision integer."
      ),
      bug_case(
        "core/int-overflow-negative-bug-001",
        "clojure.core",
        ["int"],
        "(int -2147483649)",
        "GAP-S111",
        "Clojure int coercion raises on values below the Java int range; PTC-Lisp currently returns the arbitrary-precision integer."
      ),
      bug_case(
        "core/mod-nan-bug-001",
        "clojure.core",
        ["mod"],
        "(mod ##NaN 2)",
        "GAP-S138",
        "Clojure mod raises for NaN operands; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/quot-nan-bug-001",
        "clojure.core",
        ["quot"],
        "(quot ##NaN 2)",
        "GAP-S138",
        "Clojure quot raises for NaN operands; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/rem-nan-bug-001",
        "clojure.core",
        ["rem"],
        "(rem ##NaN 2)",
        "GAP-S138",
        "Clojure rem raises for NaN operands; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/mod-nan-divisor-bug-001",
        "clojure.core",
        ["mod"],
        "(mod 2 ##NaN)",
        "GAP-S138",
        "Clojure mod raises for NaN divisors; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/quot-nan-divisor-bug-001",
        "clojure.core",
        ["quot"],
        "(quot 2 ##NaN)",
        "GAP-S138",
        "Clojure quot raises for NaN divisors; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/rem-nan-divisor-bug-001",
        "clojure.core",
        ["rem"],
        "(rem 2 ##NaN)",
        "GAP-S138",
        "Clojure rem raises for NaN divisors; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/mod-infinite-dividend-bug-001",
        "clojure.core",
        ["mod"],
        "(mod ##Inf 2)",
        "GAP-S138",
        "Clojure mod raises for infinite dividends; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/quot-infinite-dividend-bug-001",
        "clojure.core",
        ["quot"],
        "(quot ##Inf 2)",
        "GAP-S138",
        "Clojure quot raises for infinite dividends; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/rem-infinite-dividend-bug-001",
        "clojure.core",
        ["rem"],
        "(rem ##Inf 2)",
        "GAP-S138",
        "Clojure rem raises for infinite dividends; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/quot-infinite-divisor-bug-001",
        "clojure.core",
        ["quot"],
        "(quot 2 ##Inf)",
        "GAP-S138",
        "Clojure quot returns zero for an infinite divisor; PTC-Lisp currently returns NaN."
      ),
      bug_case(
        "core/int-char-bug-001",
        "clojure.core",
        ["int"],
        ~S|(int \A)|,
        "GAP-S121",
        "Clojure int coercion returns the code point for a character literal; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/int-newline-char-bug-001",
        "clojure.core",
        ["int"],
        ~S|(int \newline)|,
        "GAP-S121",
        "Clojure int coercion returns the newline code point for a character literal; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/int-tab-char-bug-001",
        "clojure.core",
        ["int"],
        ~S|(int \tab)|,
        "GAP-S121",
        "Clojure int coercion returns the tab code point for a character literal; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/format-zero-padding-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%02d" 3)|,
        "GAP-S65",
        "Clojure format honors width and zero-padding flags; PTC-Lisp currently ignores them."
      ),
      bug_case(
        "core/format-left-width-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%-4s!" "x")|,
        "GAP-S65",
        "Clojure format honors left-aligned field width; PTC-Lisp currently ignores it."
      ),
      bug_case(
        "core/format-string-width-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%5s" "x")|,
        "GAP-S65",
        "Clojure format honors right-aligned field width; PTC-Lisp currently ignores it."
      ),
      bug_case(
        "core/format-float-zero-padding-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%05.2f" 3.1)|,
        "GAP-S65",
        "Clojure format honors combined width, precision, and zero-padding flags; PTC-Lisp currently ignores the width and padding."
      ),
      bug_case(
        "core/format-plus-sign-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%+d" 3)|,
        "GAP-S65",
        "Clojure format supports the explicit plus-sign flag; PTC-Lisp currently rejects the format string."
      ),
      bug_case(
        "core/format-space-sign-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "% d" 3)|,
        "GAP-S65",
        "Clojure format supports the leading-space sign flag; PTC-Lisp currently rejects the format string."
      ),
      bug_case(
        "core/format-hex-zero-padding-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%04x" 15)|,
        "GAP-S65",
        "Clojure format honors width and zero-padding for hexadecimal conversions; PTC-Lisp currently ignores them."
      ),
      bug_case(
        "core/format-alternate-hex-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%#x" 15)|,
        "GAP-S65",
        "Clojure format supports the alternate-form flag for hexadecimal conversions; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-parentheses-negative-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%(d" -3)|,
        "GAP-S65",
        "Clojure format supports the parentheses flag for negative numbers; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-boolean-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%b %B" nil true)|,
        "GAP-S89",
        "Clojure format supports boolean conversions; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/format-newline-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "a%nb")|,
        "GAP-S89",
        "Clojure format supports the platform newline conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-newline-only-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%n")|,
        "GAP-S89",
        "Clojure format supports standalone platform newline conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-decimal-nil-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%d" nil)|,
        "GAP-S117",
        "Clojure format renders nil as null for decimal conversion; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/format-octal-nil-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%o" nil)|,
        "GAP-S117",
        "Clojure format renders nil as null for octal conversion; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/format-hex-nil-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%x" nil)|,
        "GAP-S117",
        "Clojure format renders nil as null for hexadecimal conversion; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/format-float-nil-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%f" nil)|,
        "GAP-S117",
        "Clojure format renders nil as null for floating-point conversion; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/format-uppercase-string-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%S" "ab")|,
        "GAP-S96",
        "Clojure format supports uppercase string conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-grouping-integer-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%,d" 1000)|,
        "GAP-S96",
        "Clojure format supports the grouping flag for integer conversions; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-grouping-float-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%,.2f" 1234.5)|,
        "GAP-S96",
        "Clojure format supports grouping with floating-point conversions; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-uppercase-hex-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%X" 255)|,
        "GAP-S96",
        "Clojure format supports uppercase hexadecimal conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-general-float-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%g" 1.0)|,
        "GAP-S96",
        "Clojure format supports general floating-point conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-general-precision-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%.2g" 12.34)|,
        "GAP-S96",
        "Clojure format supports precision on general floating-point conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-uppercase-general-float-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%G" 1.0)|,
        "GAP-S96",
        "Clojure format supports uppercase general floating-point conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-uppercase-exponent-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%E" 1.0)|,
        "GAP-S96",
        "Clojure format supports uppercase exponent conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-character-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%c" \A)|,
        "GAP-S96",
        "Clojure format supports character conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-hash-code-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%h" "abc")|,
        "GAP-S96",
        "Clojure format supports hash-code conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-uppercase-hash-code-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%H" "abc")|,
        "GAP-S96",
        "Clojure format supports uppercase hash-code conversion; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/format-argument-index-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%2$s %1$s" "a" "b")|,
        "GAP-S96",
        "Clojure format supports explicit argument indexes; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/format-argument-index-with-width-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%2$04d %1$s" "x" 3)|,
        "GAP-S96",
        "Clojure format supports argument indexes combined with width and padding; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/format-previous-argument-index-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%s %<s" "a")|,
        "GAP-S96",
        "Clojure format supports previous-argument indexes; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/format-date-year-conversion-bug-001",
        "clojure.core",
        ["format"],
        ~S|(format "%tY" (java.util.Date. 0))|,
        "GAP-S96",
        "Clojure format supports date/time conversions; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/re-pattern-pattern-input-bug-001",
        "clojure.core",
        ["re-pattern"],
        ~S|(re-find (re-pattern #"a+") "baac")|,
        "GAP-S66",
        "Clojure re-pattern accepts an existing pattern; PTC-Lisp currently rejects regex values."
      ),
      bug_case(
        "core/re-seq-no-match-bug-001",
        "clojure.core",
        ["re-seq"],
        ~S|(re-seq #"z" "abc")|,
        "GAP-S82",
        "Clojure re-seq returns nil when there are no matches; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/re-find-optional-capture-bug-001",
        "clojure.core",
        ["re-find"],
        ~S|(re-find #"a(\d+)?" "xa")|,
        "GAP-S92",
        "Clojure re-find includes nil slots for optional unmatched capture groups; PTC-Lisp currently collapses to the whole match string."
      ),
      bug_case(
        "core/re-matches-optional-capture-bug-001",
        "clojure.core",
        ["re-matches"],
        ~S|(re-matches #"a(\d+)?" "a")|,
        "GAP-S92",
        "Clojure re-matches includes nil slots for optional unmatched capture groups; PTC-Lisp currently collapses to the whole match string."
      ),
      bug_case(
        "core/re-seq-optional-capture-bug-001",
        "clojure.core",
        ["re-seq"],
        ~S|(re-seq #"a(\d+)?" "a a2")|,
        "GAP-S92",
        "Clojure re-seq includes nil slots for optional unmatched capture groups; PTC-Lisp currently collapses no-group matches to strings."
      ),
      bug_case(
        "core/re-find-leading-optional-capture-bug-001",
        "clojure.core",
        ["re-find"],
        ~S|(re-find #"(a)?(b)" "b")|,
        "GAP-S92",
        "Clojure re-find returns nil for an unmatched optional leading capture; PTC-Lisp currently returns an empty string slot."
      ),
      bug_case(
        "core/re-matches-leading-optional-capture-bug-001",
        "clojure.core",
        ["re-matches"],
        ~S|(re-matches #"(a)?(b)" "b")|,
        "GAP-S92",
        "Clojure re-matches returns nil for an unmatched optional leading capture; PTC-Lisp currently returns an empty string slot."
      ),
      bug_case(
        "core/re-seq-leading-optional-capture-bug-001",
        "clojure.core",
        ["re-seq"],
        ~S|(re-seq #"(a)?(b)" "b ab")|,
        "GAP-S92",
        "Clojure re-seq returns nil for unmatched optional leading captures; PTC-Lisp currently returns empty string slots."
      ),
      bug_case(
        "core/re-find-multiple-optional-captures-bug-001",
        "clojure.core",
        ["re-find"],
        ~S|(re-find #"(a)?(b)?(c)" "c")|,
        "GAP-S92",
        "Clojure re-find preserves nil slots for multiple unmatched optional captures; PTC-Lisp currently returns empty strings."
      ),
      bug_case(
        "core/re-matches-multiple-optional-captures-bug-001",
        "clojure.core",
        ["re-matches"],
        ~S|(re-matches #"(a)?(b)?(c)" "c")|,
        "GAP-S92",
        "Clojure re-matches preserves nil slots for multiple unmatched optional captures; PTC-Lisp currently returns empty strings."
      ),
      bug_case(
        "core/re-seq-multiple-optional-captures-bug-001",
        "clojure.core",
        ["re-seq"],
        ~S|(re-seq #"(a)?(b)?(c)" "c abc")|,
        "GAP-S92",
        "Clojure re-seq preserves nil slots for multiple unmatched optional captures; PTC-Lisp currently returns empty strings."
      ),
      bug_case(
        "core/re-find-char-input-bug-001",
        "clojure.core",
        ["re-find"],
        ~S|(re-find #"a" \a)|,
        "GAP-S131",
        "Clojure re-find rejects Character input strings; PTC-Lisp currently treats character literals as strings."
      ),
      bug_case(
        "core/re-matches-char-input-bug-001",
        "clojure.core",
        ["re-matches"],
        ~S|(re-matches #"a" \a)|,
        "GAP-S131",
        "Clojure re-matches rejects Character input strings; PTC-Lisp currently treats character literals as strings."
      ),
      bug_case(
        "core/re-seq-char-input-bug-001",
        "clojure.core",
        ["re-seq"],
        ~S|(re-seq #"a" \a)|,
        "GAP-S131",
        "Clojure re-seq rejects Character input strings; PTC-Lisp currently treats character literals as strings."
      ),
      bug_case(
        "core/re-pattern-char-bug-001",
        "clojure.core",
        ["re-pattern"],
        ~S|(re-pattern \a)|,
        "GAP-S131",
        "Clojure re-pattern rejects Character patterns; PTC-Lisp currently treats character literals as strings."
      ),
      bug_case(
        "core/str-regex-bug-001",
        "clojure.core",
        ["str"],
        ~S|(str #"a+")|,
        "GAP-S93",
        "Clojure str on a regex pattern returns its source pattern text; PTC-Lisp currently leaks the internal regex tuple representation."
      ),
      bug_case(
        "core/str-empty-regex-bug-001",
        "clojure.core",
        ["str"],
        ~S|(str (re-pattern ""))|,
        "GAP-S93",
        "Clojure str on an empty regex pattern returns the source pattern text; PTC-Lisp currently leaks the internal regex tuple representation."
      ),
      bug_case(
        "core/pr-str-char-bug-001",
        "clojure.core",
        ["pr-str"],
        ~S|(pr-str \a)|,
        "GAP-S126",
        "Clojure pr-str prints Character values with character syntax; PTC-Lisp currently prints them as strings."
      ),
      bug_case(
        "core/pr-str-newline-char-bug-001",
        "clojure.core",
        ["pr-str"],
        ~S|(pr-str \newline)|,
        "GAP-S126",
        "Clojure pr-str prints named Character values with character syntax; PTC-Lisp currently prints them as strings."
      ),
      bug_case(
        "core/name-char-bug-001",
        "clojure.core",
        ["name"],
        ~S|(name \a)|,
        "GAP-S129",
        "Clojure name rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/name-newline-char-bug-001",
        "clojure.core",
        ["name"],
        ~S|(name \newline)|,
        "GAP-S129",
        "Clojure name rejects named Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/count-char-bug-001",
        "clojure.core",
        ["count"],
        ~S|(count \a)|,
        "GAP-S130",
        "Clojure count rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/seq-char-bug-001",
        "clojure.core",
        ["seq"],
        ~S|(seq \a)|,
        "GAP-S130",
        "Clojure seq rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/first-char-bug-001",
        "clojure.core",
        ["first"],
        ~S|(first \a)|,
        "GAP-S130",
        "Clojure first rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/nth-char-bug-001",
        "clojure.core",
        ["nth"],
        ~S|(nth \a 0)|,
        "GAP-S130",
        "Clojure nth rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/vec-char-bug-001",
        "clojure.core",
        ["vec"],
        ~S|(vec \a)|,
        "GAP-S130",
        "Clojure vec rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/not-empty-char-bug-001",
        "clojure.core",
        ["not-empty"],
        ~S|(not-empty \a)|,
        "GAP-S130",
        "Clojure not-empty rejects Character values; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/map-char-bug-001",
        "clojure.core",
        ["map"],
        ~S|(map identity \a)|,
        "GAP-S130",
        "Clojure map rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/filterv-char-bug-001",
        "clojure.core",
        ["filterv"],
        ~S|(filterv identity \a)|,
        "GAP-S130",
        "Clojure filterv rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/reduce-char-bug-001",
        "clojure.core",
        ["reduce"],
        ~S|(reduce str \a)|,
        "GAP-S130",
        "Clojure reduce rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/frequencies-char-bug-001",
        "clojure.core",
        ["frequencies"],
        ~S|(frequencies \a)|,
        "GAP-S130",
        "Clojure frequencies rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/partition-all-char-bug-001",
        "clojure.core",
        ["partition-all"],
        ~S|(partition-all 1 \a)|,
        "GAP-S130",
        "Clojure partition-all rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/cons-char-bug-001",
        "clojure.core",
        ["cons"],
        ~S|(cons :x \a)|,
        "GAP-S130",
        "Clojure cons rejects Character tail collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/zipmap-char-keys-bug-001",
        "clojure.core",
        ["zipmap"],
        ~S|(zipmap \a [1])|,
        "GAP-S130",
        "Clojure zipmap rejects Character key collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/zipmap-char-vals-bug-001",
        "clojure.core",
        ["zipmap"],
        ~S|(zipmap [:a] \b)|,
        "GAP-S130",
        "Clojure zipmap rejects Character value collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/dedupe-char-bug-001",
        "clojure.core",
        ["dedupe"],
        ~S|(dedupe \a)|,
        "GAP-S130",
        "Clojure dedupe rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/drop-last-char-bug-001",
        "clojure.core",
        ["drop-last"],
        ~S|(drop-last 1 \a)|,
        "GAP-S130",
        "Clojure drop-last rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/drop-while-char-bug-001",
        "clojure.core",
        ["drop-while"],
        ~S|(drop-while identity \a)|,
        "GAP-S130",
        "Clojure drop-while rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/take-while-char-bug-001",
        "clojure.core",
        ["take-while"],
        ~S|(take-while identity \a)|,
        "GAP-S130",
        "Clojure take-while rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/remove-char-bug-001",
        "clojure.core",
        ["remove"],
        ~S|(remove identity \a)|,
        "GAP-S130",
        "Clojure remove rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/not-every-char-bug-001",
        "clojure.core",
        ["not-every?"],
        ~S|(not-every? identity \a)|,
        "GAP-S130",
        "Clojure not-every? rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/rest-char-bug-001",
        "clojure.core",
        ["rest"],
        ~S|(rest \a)|,
        "GAP-S130",
        "Clojure rest rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/next-char-bug-001",
        "clojure.core",
        ["next"],
        ~S|(next \a)|,
        "GAP-S130",
        "Clojure next rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/last-char-bug-001",
        "clojure.core",
        ["last"],
        ~S|(last \a)|,
        "GAP-S130",
        "Clojure last rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/second-char-bug-001",
        "clojure.core",
        ["second"],
        ~S|(second \a)|,
        "GAP-S130",
        "Clojure second rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/butlast-char-bug-001",
        "clojure.core",
        ["butlast"],
        ~S|(butlast \a)|,
        "GAP-S130",
        "Clojure butlast rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/nthnext-char-bug-001",
        "clojure.core",
        ["nthnext"],
        ~S|(nthnext \a 1)|,
        "GAP-S130",
        "Clojure nthnext rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/nthrest-char-bug-001",
        "clojure.core",
        ["nthrest"],
        ~S|(nthrest \a 1)|,
        "GAP-S130",
        "Clojure nthrest rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/split-at-char-bug-001",
        "clojure.core",
        ["split-at"],
        ~S|(split-at 1 \a)|,
        "GAP-S130",
        "Clojure split-at rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/split-with-char-bug-001",
        "clojure.core",
        ["split-with"],
        ~S|(split-with identity \a)|,
        "GAP-S130",
        "Clojure split-with rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/keep-char-bug-001",
        "clojure.core",
        ["keep"],
        ~S|(keep identity \a)|,
        "GAP-S130",
        "Clojure keep rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/keep-indexed-char-bug-001",
        "clojure.core",
        ["keep-indexed"],
        ~S|(keep-indexed vector \a)|,
        "GAP-S130",
        "Clojure keep-indexed rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/every-char-bug-001",
        "clojure.core",
        ["every?"],
        ~S|(every? identity \a)|,
        "GAP-S130",
        "Clojure every? rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/some-char-bug-001",
        "clojure.core",
        ["some"],
        ~S|(some identity \a)|,
        "GAP-S130",
        "Clojure some rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/not-any-char-bug-001",
        "clojure.core",
        ["not-any?"],
        ~S|(not-any? identity \a)|,
        "GAP-S130",
        "Clojure not-any? rejects Character collections; PTC-Lisp currently treats character literals as one-character strings."
      ),
      regression_case(
        "core/assoc-in-empty-path-001",
        "clojure.core",
        ["assoc-in"],
        "(assoc-in {:a 1} [] 2)",
        ["GAP-S68"],
        [:collection]
      ),
      regression_case(
        "core/assoc-in-empty-map-empty-path-001",
        "clojure.core",
        ["assoc-in"],
        "(assoc-in {} [] 1)",
        ["GAP-S68"],
        [:collection]
      ),
      regression_case(
        "core/assoc-in-nil-path-001",
        "clojure.core",
        ["assoc-in"],
        "(assoc-in {:a 1} nil 2)",
        ["GAP-S68"],
        [:collection]
      ),
      regression_case(
        "core/assoc-one-arity-001",
        "clojure.core",
        ["assoc"],
        "(assoc {})",
        ["GAP-S105"],
        [:collection]
      ),
      bug_case(
        "core/divide-float-zero-bug-001",
        "clojure.core",
        ["/"],
        "(/ 1.0 0.0)",
        "GAP-S69",
        "Clojure division by zero raises even for floating inputs; PTC-Lisp currently returns infinity."
      ),
      bug_case(
        "core/counted-string-bug-001",
        "clojure.core",
        ["counted?"],
        ~S|(counted? "ab")|,
        "GAP-S70",
        "Clojure counted? returns false for strings; PTC-Lisp currently returns true."
      ),
      bug_case(
        "core/indexed-string-bug-001",
        "clojure.core",
        ["indexed?"],
        ~S|(indexed? "ab")|,
        "GAP-S70",
        "Clojure indexed? returns false for strings; PTC-Lisp currently returns true."
      ),
      bug_case(
        "core/reversible-string-bug-001",
        "clojure.core",
        ["reversible?"],
        ~S|(reversible? "ab")|,
        "GAP-S70",
        "Clojure reversible? returns false for strings; PTC-Lisp currently returns true."
      ),
      bug_case(
        "core/map-map-function-bug-001",
        "clojure.core",
        ["map"],
        "(map {:a 1 :b 2} [:a :c :b])",
        "GAP-S71",
        "Clojure maps are invokable lookup functions; PTC-Lisp currently rejects maps in map function position."
      ),
      bug_case(
        "core/map-vector-function-bug-001",
        "clojure.core",
        ["map"],
        "(map [10 20] [0 1])",
        "GAP-S71",
        "Clojure vectors are invokable index lookup functions; PTC-Lisp currently rejects vectors in map function position."
      ),
      bug_case(
        "core/filter-map-function-bug-001",
        "clojure.core",
        ["filter"],
        "(filter {:a true :b false} [:a :b :c])",
        "GAP-S71",
        "Clojure maps are invokable predicates by lookup truthiness; PTC-Lisp currently rejects maps in filter predicate position."
      ),
      bug_case(
        "core/some-map-function-bug-001",
        "clojure.core",
        ["some"],
        "(some {:a 1 :b 2} [:c :b :a])",
        "GAP-S71",
        "Clojure some accepts maps as invokable lookup functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/some-vector-function-bug-001",
        "clojure.core",
        ["some"],
        "(some [nil :x] [0 1])",
        "GAP-S71",
        "Clojure some accepts vectors as invokable lookup functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/keep-map-function-bug-001",
        "clojure.core",
        ["keep"],
        "(keep {:a 1 :b nil :c false} [:a :b :c :d])",
        "GAP-S71",
        "Clojure keep accepts maps as invokable lookup functions and keeps false; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/every-map-function-bug-001",
        "clojure.core",
        ["every?"],
        "(every? {:a true :b true} [:a :b])",
        "GAP-S71",
        "Clojure every? accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/every-vector-function-bug-001",
        "clojure.core",
        ["every?"],
        "(every? [true true] [0 1])",
        "GAP-S71",
        "Clojure every? accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/not-any-map-function-bug-001",
        "clojure.core",
        ["not-any?"],
        "(not-any? {:a true} [:b :c])",
        "GAP-S71",
        "Clojure not-any? accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/not-any-vector-function-bug-001",
        "clojure.core",
        ["not-any?"],
        "(not-any? [nil false] [0 1])",
        "GAP-S71",
        "Clojure not-any? accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "walk/prewalk-map-function-bug-001",
        "clojure.walk",
        ["prewalk"],
        "(clojure.walk/prewalk {:a :x} [:a :b])",
        "GAP-S71",
        "Clojure prewalk accepts maps as invokable transform functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "walk/prewalk-set-function-bug-001",
        "clojure.walk",
        ["prewalk"],
        ~S|(clojure.walk/prewalk #{:a} [:a :b])|,
        "GAP-S71",
        "Clojure prewalk accepts sets as invokable transform functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "walk/postwalk-map-function-bug-001",
        "clojure.walk",
        ["postwalk"],
        "(clojure.walk/postwalk {:a :x} [:a :b])",
        "GAP-S71",
        "Clojure postwalk accepts maps as invokable transform functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "walk/postwalk-set-function-bug-001",
        "clojure.walk",
        ["postwalk"],
        ~S|(clojure.walk/postwalk #{:a} [:a :b])|,
        "GAP-S71",
        "Clojure postwalk accepts sets as invokable transform functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "walk/walk-map-function-bug-001",
        "clojure.walk",
        ["walk"],
        "(clojure.walk/walk {:a :x} identity [:a :b])",
        "GAP-S71",
        "Clojure walk accepts maps as invokable inner transform functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "walk/walk-set-function-bug-001",
        "clojure.walk",
        ["walk"],
        ~S|(clojure.walk/walk #{:a} identity [:a :b])|,
        "GAP-S71",
        "Clojure walk accepts sets as invokable inner transform functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "walk/walk-vector-function-bug-001",
        "clojure.walk",
        ["walk"],
        "(clojure.walk/walk [10 20] identity [1])",
        "GAP-S71",
        "Clojure walk accepts vectors as invokable inner transform functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/comp-map-function-bug-001",
        "clojure.core",
        ["comp"],
        "((comp inc {:a 1}) :a)",
        "GAP-S71",
        "Clojure comp accepts maps as invokable functions; PTC-Lisp currently rejects maps inside composed functions."
      ),
      bug_case(
        "core/comp-set-function-bug-001",
        "clojure.core",
        ["comp"],
        ~S|((comp boolean #{:a}) :a)|,
        "GAP-S71",
        "Clojure comp accepts sets as invokable functions; PTC-Lisp currently rejects sets inside composed functions."
      ),
      bug_case(
        "core/comp-vector-function-bug-001",
        "clojure.core",
        ["comp"],
        "((comp [10 20]) 1)",
        "GAP-S71",
        "Clojure comp accepts vectors as invokable index lookup functions; PTC-Lisp currently rejects vectors inside composed functions."
      ),
      bug_case(
        "core/partial-map-function-bug-001",
        "clojure.core",
        ["partial"],
        "((partial {:a 1}) :a)",
        "GAP-S71",
        "Clojure partial accepts maps as invokable functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/partial-set-function-bug-001",
        "clojure.core",
        ["partial"],
        ~S|((partial #{:a}) :a)|,
        "GAP-S71",
        "Clojure partial accepts sets as invokable functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/partial-vector-function-bug-001",
        "clojure.core",
        ["partial"],
        "((partial [10 20]) 1)",
        "GAP-S71",
        "Clojure partial accepts vectors as invokable index lookup functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/juxt-map-set-function-bug-001",
        "clojure.core",
        ["juxt"],
        ~S|((juxt #{:a} {:a 1}) :a)|,
        "GAP-S71",
        "Clojure juxt accepts sets and maps as invokable functions; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/juxt-vector-function-bug-001",
        "clojure.core",
        ["juxt"],
        "((juxt [10 20] :a) 1)",
        "GAP-S71",
        "Clojure juxt accepts vectors as invokable index lookup functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/complement-map-function-bug-001",
        "clojure.core",
        ["complement"],
        "((complement {:a true}) :b)",
        "GAP-S71",
        "Clojure complement accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/complement-set-function-bug-001",
        "clojure.core",
        ["complement"],
        ~S|((complement #{:a}) :b)|,
        "GAP-S71",
        "Clojure complement accepts sets as invokable predicates; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/every-pred-map-function-bug-001",
        "clojure.core",
        ["every-pred"],
        "((every-pred {:a true} {:a 1}) :a)",
        "GAP-S71",
        "Clojure every-pred accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/every-pred-set-function-bug-001",
        "clojure.core",
        ["every-pred"],
        ~S|((every-pred #{:a}) :a)|,
        "GAP-S71",
        "Clojure every-pred accepts sets as invokable predicates; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/every-pred-vector-function-bug-001",
        "clojure.core",
        ["every-pred"],
        "((every-pred [true]) 0)",
        "GAP-S71",
        "Clojure every-pred accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/some-fn-map-function-bug-001",
        "clojure.core",
        ["some-fn"],
        "((some-fn {:a nil} {:b 2}) :b)",
        "GAP-S71",
        "Clojure some-fn accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/some-fn-set-function-bug-001",
        "clojure.core",
        ["some-fn"],
        ~S|((some-fn #{:a}) :a)|,
        "GAP-S71",
        "Clojure some-fn accepts sets as invokable predicates; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/some-fn-vector-function-bug-001",
        "clojure.core",
        ["some-fn"],
        "((some-fn [nil :x]) 1)",
        "GAP-S71",
        "Clojure some-fn accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/fnil-map-function-bug-001",
        "clojure.core",
        ["fnil"],
        "((fnil {:a 1} :x) nil)",
        "GAP-S71",
        "Clojure fnil accepts maps as invokable functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/fnil-keyword-function-bug-001",
        "clojure.core",
        ["fnil"],
        "((fnil :a :x) nil)",
        "GAP-S71",
        "Clojure fnil accepts keywords as invokable functions; PTC-Lisp currently rejects keywords in fnil function position."
      ),
      bug_case(
        "core/fnil-set-function-bug-001",
        "clojure.core",
        ["fnil"],
        ~S|((fnil #{:a} :x) nil)|,
        "GAP-S71",
        "Clojure fnil accepts sets as invokable functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/fnil-vector-function-bug-001",
        "clojure.core",
        ["fnil"],
        "((fnil [10 20] 0) nil)",
        "GAP-S71",
        "Clojure fnil accepts vectors as invokable index lookup functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/partition-by-map-function-bug-001",
        "clojure.core",
        ["partition-by"],
        "(partition-by {:a 1 :b 2} [:a :a :b])",
        "GAP-S71",
        "Clojure partition-by accepts maps as invokable functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/partition-by-vector-function-bug-001",
        "clojure.core",
        ["partition-by"],
        "(partition-by [0 1] [0 0 1])",
        "GAP-S71",
        "Clojure partition-by accepts vectors as invokable functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/drop-while-map-function-bug-001",
        "clojure.core",
        ["drop-while"],
        "(drop-while {:a true :b false} [:a :b :c])",
        "GAP-S71",
        "Clojure drop-while accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/drop-while-vector-function-bug-001",
        "clojure.core",
        ["drop-while"],
        "(drop-while [true false] [0 1])",
        "GAP-S71",
        "Clojure drop-while accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/take-while-map-function-bug-001",
        "clojure.core",
        ["take-while"],
        "(take-while {:a true :b false} [:a :b :c])",
        "GAP-S71",
        "Clojure take-while accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/take-while-vector-function-bug-001",
        "clojure.core",
        ["take-while"],
        "(take-while [true false] [0 1])",
        "GAP-S71",
        "Clojure take-while accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/split-with-map-function-bug-001",
        "clojure.core",
        ["split-with"],
        "(split-with {:a true :b false} [:a :b :c])",
        "GAP-S71",
        "Clojure split-with accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/split-with-vector-function-bug-001",
        "clojure.core",
        ["split-with"],
        "(split-with [true false] [0 1])",
        "GAP-S71",
        "Clojure split-with accepts vectors as invokable predicates; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/map-indexed-map-function-bug-001",
        "clojure.core",
        ["map-indexed"],
        "(map-indexed {0 :z 1 :o} [:a :b])",
        "GAP-S71",
        "Clojure map-indexed accepts maps as invokable functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/keep-indexed-map-function-bug-001",
        "clojure.core",
        ["keep-indexed"],
        "(keep-indexed {0 :z 1 nil 2 false} [:a :b :c])",
        "GAP-S71",
        "Clojure keep-indexed accepts maps as invokable functions and keeps false; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/keep-vector-function-bug-001",
        "clojure.core",
        ["keep"],
        "(keep [nil :x] [0 1])",
        "GAP-S71",
        "Clojure keep accepts vectors as invokable index lookup functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/mapcat-map-function-bug-001",
        "clojure.core",
        ["mapcat"],
        "(mapcat {0 [1 2]} [0])",
        "GAP-S71",
        "Clojure mapcat accepts maps as invokable functions before concatenating results; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/mapcat-vector-function-bug-001",
        "clojure.core",
        ["mapcat"],
        "(mapcat [[1] [2]] [0 1])",
        "GAP-S71",
        "Clojure mapcat accepts vectors as invokable functions before concatenating results; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/filterv-map-function-bug-001",
        "clojure.core",
        ["filterv"],
        "(filterv {:a true :b false} [:a :b :c])",
        "GAP-S71",
        "Clojure filterv accepts maps as invokable predicates; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/mapv-map-function-bug-001",
        "clojure.core",
        ["mapv"],
        "(mapv {:a 1 :b 2} [:a :b])",
        "GAP-S71",
        "Clojure mapv accepts maps as invokable functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/mapv-vector-function-bug-001",
        "clojure.core",
        ["mapv"],
        "(mapv [10 20] [0 1])",
        "GAP-S71",
        "Clojure mapv accepts vectors as invokable functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/group-by-map-function-bug-001",
        "clojure.core",
        ["group-by"],
        "(group-by {:a 1 :b 2} [:a :b :c])",
        "GAP-S71",
        "Clojure group-by accepts maps as invokable key functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/group-by-set-function-bug-001",
        "clojure.core",
        ["group-by"],
        ~S|(group-by #{:a} [:a :b])|,
        "GAP-S71",
        "Clojure group-by accepts sets as invokable key functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/group-by-vector-function-bug-001",
        "clojure.core",
        ["group-by"],
        "(group-by [0 1] [0 1])",
        "GAP-S71",
        "Clojure group-by accepts vectors as invokable key functions; PTC-Lisp currently groups under nil."
      ),
      bug_case(
        "core/reduce-map-function-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce {:a 1 :b 2} [:a :b])",
        "GAP-S71",
        "Clojure reduce accepts maps as invokable reducing functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/reduce-map-function-singleton-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce {:a 1 :b 2} [:a])",
        "GAP-S71",
        "Clojure reduce accepts maps as invokable reducing functions even when no reducing call is needed after the singleton first value; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/reduce-map-function-init-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce {:a 1 :b 2} nil [:a])",
        "GAP-S71",
        "Clojure reduce accepts maps as invokable reducing functions in the explicit-init arity; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/sort-by-map-function-bug-001",
        "clojure.core",
        ["sort-by"],
        "(sort-by {:a 2 :b 1} [:a :b])",
        "GAP-S71",
        "Clojure sort-by accepts maps as invokable key functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/sort-by-vector-function-bug-001",
        "clojure.core",
        ["sort-by"],
        "(sort-by [2 1] [0 1])",
        "GAP-S71",
        "Clojure sort-by accepts vectors as invokable key functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/max-key-map-function-bug-001",
        "clojure.core",
        ["max-key"],
        "(max-key {:a 1 :b 2} :a :b)",
        "GAP-S71",
        "Clojure max-key accepts maps as invokable key functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/max-key-vector-function-bug-001",
        "clojure.core",
        ["max-key"],
        "(max-key [1 2] 0 1)",
        "GAP-S71",
        "Clojure max-key accepts vectors as invokable key functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/min-key-map-function-bug-001",
        "clojure.core",
        ["min-key"],
        "(min-key {:a 1 :b 2} :a :b)",
        "GAP-S71",
        "Clojure min-key accepts maps as invokable key functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/min-key-vector-function-bug-001",
        "clojure.core",
        ["min-key"],
        "(min-key [1 2] 0 1)",
        "GAP-S71",
        "Clojure min-key accepts vectors as invokable key functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/group-by-string-bug-001",
        "clojure.core",
        ["group-by"],
        ~S|(group-by identity "aba")|,
        "GAP-S67",
        "Clojure group-by accepts seqable strings; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/distinct-predicate-zero-arity-bug-001",
        "clojure.core",
        ["distinct?"],
        "(distinct?)",
        "GAP-S64",
        "Clojure distinct? requires at least one argument; PTC-Lisp currently accepts zero arguments."
      ),
      bug_case(
        "core/distinct-predicate-nan-bug-001",
        "clojure.core",
        ["distinct?"],
        "(distinct? ##NaN ##NaN)",
        "GAP-S101",
        "Clojure distinct? treats repeated NaN values as distinct; PTC-Lisp currently treats them as duplicates."
      ),
      bug_case(
        "core/distinct-predicate-three-nan-bug-001",
        "clojure.core",
        ["distinct?"],
        "(distinct? ##NaN ##NaN ##NaN)",
        "GAP-S101",
        "Clojure distinct? treats each NaN value as distinct even across three arguments; PTC-Lisp currently treats them as duplicates."
      ),
      bug_case(
        "core/distinct-predicate-separated-nan-bug-001",
        "clojure.core",
        ["distinct?"],
        "(distinct? ##NaN 1 ##NaN)",
        "GAP-S101",
        "Clojure distinct? treats separated repeated NaN values as distinct; PTC-Lisp currently treats them as duplicates."
      ),
      bug_case(
        "core/take-nil-bug-001",
        "clojure.core",
        ["take"],
        "(take 2 nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/flatten-scalar-bug-001",
        "clojure.core",
        ["flatten"],
        "(flatten 1)",
        "GAP-S81",
        "Clojure flatten returns an empty seq for a scalar root; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/flatten-string-bug-001",
        "clojure.core",
        ["flatten"],
        ~S|(flatten "ab")|,
        "GAP-S81",
        "Clojure flatten returns an empty seq for a string root; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/flatten-char-bug-001",
        "clojure.core",
        ["flatten"],
        ~S|(flatten \a)|,
        "GAP-S81",
        "Clojure flatten returns an empty seq for a character root; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/flatten-map-bug-001",
        "clojure.core",
        ["flatten"],
        "(flatten {:a [1 2]})",
        "GAP-S81",
        "Clojure flatten returns an empty seq for a map root; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/drop-nil-bug-001",
        "clojure.core",
        ["drop"],
        "(drop 2 nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/frequencies-nil-bug-001",
        "clojure.core",
        ["frequencies"],
        "(frequencies nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/frequencies-map-bug-001",
        "clojure.core",
        ["frequencies"],
        "(frequencies {:a 1})",
        "GAP-S20",
        "Clojure treats maps as seqable map entries; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/flatten-nil-bug-001",
        "clojure.core",
        ["flatten"],
        "(flatten nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/distinct-nil-bug-001",
        "clojure.core",
        ["distinct"],
        "(distinct nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/distinct-map-bug-001",
        "clojure.core",
        ["distinct"],
        "(distinct {:a 1 :b 2})",
        "GAP-S134",
        "Clojure distinct raises on direct map input; PTC-Lisp currently returns map entries."
      ),
      bug_case(
        "core/interleave-left-nil-bug-001",
        "clojure.core",
        ["interleave"],
        "(interleave nil [1])",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/interleave-right-nil-bug-001",
        "clojure.core",
        ["interleave"],
        "(interleave [1] nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/interleave-string-bug-001",
        "clojure.core",
        ["interleave"],
        ~S|(interleave "ab" [1 2])|,
        "GAP-S98",
        "Clojure interleave treats strings as seqable; PTC-Lisp currently rejects them."
      ),
      regression_case(
        "core/interleave-one-coll-001",
        "clojure.core",
        ["interleave"],
        "(interleave [1 2])",
        ["GAP-S143"],
        [:collection]
      ),
      bug_case(
        "core/map-multi-string-bug-001",
        "clojure.core",
        ["map"],
        ~S|(map vector "ab" [1 2])|,
        "GAP-S102",
        "Clojure map treats strings as seqable in multi-collection arity; PTC-Lisp currently rejects strings there."
      ),
      bug_case(
        "core/reverse-nil-bug-001",
        "clojure.core",
        ["reverse"],
        "(reverse nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/sort-nil-input-bug-001",
        "clojure.core",
        ["sort"],
        "(sort nil)",
        "GAP-S20",
        "Clojure treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/reduce-empty-no-init-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce + [])",
        "GAP-S21",
        "Clojure reduce calls the reducing function's zero-arity form on empty input; PTC-Lisp returns nil."
      ),
      bug_case(
        "core/reduce-nil-no-init-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce + nil)",
        "GAP-S21",
        "Clojure reduce calls the reducing function's zero-arity form on nil input; PTC-Lisp returns nil."
      ),
      bug_case(
        "core/reduce-vector-empty-no-init-bug-001",
        "clojure.core",
        ["reduce"],
        "(reduce vector [])",
        "GAP-S21",
        "Clojure reduce calls the reducing function's zero-arity form on empty input; PTC-Lisp returns nil."
      ),
      bug_case(
        "core/reduce-kv-vector-bug-001",
        "clojure.core",
        ["reduce-kv"],
        "(reduce-kv (fn [acc k v] (conj acc [k v])) [] [:a :b])",
        "GAP-S59",
        "Clojure reduce-kv supports vectors with numeric indexes; PTC-Lisp currently requires a map."
      ),
      bug_case(
        "core/reduce-kv-empty-vector-bug-001",
        "clojure.core",
        ["reduce-kv"],
        "(reduce-kv (fn [acc k v] (conj acc [k v])) [] [])",
        "GAP-S59",
        "Clojure reduce-kv supports empty vectors as indexed associative collections; PTC-Lisp currently requires a map."
      ),
      regression_case(
        "core/interpose-string-001",
        "clojure.core",
        ["interpose"],
        ~S|(interpose "," "ab")|,
        ["GAP-S60"],
        [:collection]
      ),
      regression_case(
        "core/interpose-empty-string-001",
        "clojure.core",
        ["interpose"],
        ~S|(interpose "," "")|,
        ["GAP-S60"],
        [:collection]
      ),
      bug_case(
        "core/get-in-default-present-nil-bug-001",
        "clojure.core",
        ["get-in"],
        "(get-in {:a nil} [:a] :missing)",
        "GAP-S22",
        "Clojure get-in returns an explicitly present nil value; PTC-Lisp returns the default."
      ),
      bug_case(
        "core/get-in-default-nested-present-nil-bug-001",
        "clojure.core",
        ["get-in"],
        "(get-in {:a {:b nil}} [:a :b] :missing)",
        "GAP-S22",
        "Clojure get-in returns an explicitly present nested nil value; PTC-Lisp returns the default."
      ),
      bug_case(
        "core/get-in-default-vector-present-nil-bug-001",
        "clojure.core",
        ["get-in"],
        "(get-in [nil :b] [0] :missing)",
        "GAP-S22",
        "Clojure get-in returns an explicitly present nil vector value; PTC-Lisp returns the default."
      ),
      bug_case(
        "core/select-keys-nil-keys-bug-001",
        "clojure.core",
        ["select-keys"],
        "(select-keys {:a 1} nil)",
        "GAP-S23",
        "Clojure treats nil keyseq as empty; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/select-keys-string-keys-bug-001",
        "clojure.core",
        ["select-keys"],
        ~S|(select-keys {:a 1 :b 2} ":a")|,
        "GAP-S23",
        "Clojure treats a string keyseq as seqable characters; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/update-keys-nil-bug-001",
        "clojure.core",
        ["update-keys"],
        "(update-keys nil name)",
        "GAP-S24",
        "Clojure treats nil maps as empty for update-keys; PTC-Lisp returns nil."
      ),
      bug_case(
        "core/update-vals-nil-bug-001",
        "clojure.core",
        ["update-vals"],
        "(update-vals nil inc)",
        "GAP-S24",
        "Clojure treats nil maps as empty for update-vals; PTC-Lisp returns nil."
      ),
      bug_case(
        "core/update-keys-map-function-bug-001",
        "clojure.core",
        ["update-keys"],
        "(update-keys {:a 1 :b 2} {:a :x :b :y})",
        "GAP-S71",
        "Clojure update-keys accepts maps as invokable key transform functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/update-keys-set-function-bug-001",
        "clojure.core",
        ["update-keys"],
        ~S|(update-keys {:a 1 :b 2} #{:a})|,
        "GAP-S71",
        "Clojure update-keys accepts sets as invokable key transform functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/update-keys-vector-function-bug-001",
        "clojure.core",
        ["update-keys"],
        "(update-keys {0 :a 1 :b} [:x :y])",
        "GAP-S71",
        "Clojure update-keys accepts vectors as invokable key transform functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/update-vals-map-function-bug-001",
        "clojure.core",
        ["update-vals"],
        "(update-vals {:a :x :b :y} {:x 1 :y 2})",
        "GAP-S71",
        "Clojure update-vals accepts maps as invokable value transform functions; PTC-Lisp currently rejects maps."
      ),
      bug_case(
        "core/update-vals-set-function-bug-001",
        "clojure.core",
        ["update-vals"],
        ~S|(update-vals {:a :x :b :z} #{:x})|,
        "GAP-S71",
        "Clojure update-vals accepts sets as invokable value transform functions; PTC-Lisp currently rejects sets."
      ),
      bug_case(
        "core/update-vals-vector-function-bug-001",
        "clojure.core",
        ["update-vals"],
        "(update-vals {:a 0 :b 1} [:x :y])",
        "GAP-S71",
        "Clojure update-vals accepts vectors as invokable value transform functions; PTC-Lisp currently rejects vectors."
      ),
      bug_case(
        "core/update-keys-vector-bug-001",
        "clojure.core",
        ["update-keys"],
        "(update-keys [10 20] inc)",
        "GAP-S75",
        "Clojure update-keys accepts vectors as associative collections; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/update-keys-empty-vector-bug-001",
        "clojure.core",
        ["update-keys"],
        "(update-keys [] inc)",
        "GAP-S75",
        "Clojure update-keys accepts empty vectors as associative collections; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/update-vals-vector-bug-001",
        "clojure.core",
        ["update-vals"],
        "(update-vals [10 20] inc)",
        "GAP-S75",
        "Clojure update-vals accepts vectors as associative collections; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/update-vals-empty-vector-bug-001",
        "clojure.core",
        ["update-vals"],
        "(update-vals [] inc)",
        "GAP-S75",
        "Clojure update-vals accepts empty vectors as associative collections; PTC-Lisp currently requires maps."
      ),
      bug_case(
        "core/conj-map-source-bug-001",
        "clojure.core",
        ["conj"],
        "(conj {:a 1} {:b 2})",
        "GAP-S76",
        "Clojure conj accepts a map as a source of map entries when conjoining into a map; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/conj-map-list-entry-bug-001",
        "clojure.core",
        ["conj"],
        "(conj {:a 1} (list :b 2))",
        "GAP-S137",
        "Clojure requires map-entry values when conjoining into a map; PTC-Lisp currently treats a two-item list as a map entry."
      ),
      regression_case(
        "core/conj-zero-arity-001",
        "clojure.core",
        ["conj"],
        "(conj)",
        ["GAP-S106"],
        [:collection]
      ),
      bug_case(
        "walk/walk-invalid-map-entry-bug-001",
        "clojure.walk",
        ["walk"],
        "(clojure.walk/walk reverse identity {:a [1 2]})",
        "GAP-S91",
        "Clojure walk raises when an inner transform turns a map entry into a non-entry vector; PTC-Lisp currently rebuilds a map from the invalid entry shape."
      ),
      bug_case(
        "core/tree-seq-string-root-bug-001",
        "clojure.core",
        ["tree-seq"],
        ~S|(tree-seq string? seq "ab")|,
        "GAP-S77",
        "Clojure tree-seq over a string root terminates over characters; PTC-Lisp currently recurses until the heap limit."
      ),
      bug_case(
        "core/minus-zero-arity-bug-001",
        "clojure.core",
        ["-"],
        "(-)",
        "GAP-S28",
        "Clojure rejects zero-arity subtraction; PTC-Lisp currently returns 0."
      ),
      bug_case(
        "core/divide-unary-bug-001",
        "clojure.core",
        ["/"],
        "(/ 2)",
        "GAP-S29",
        "Clojure unary division returns the reciprocal; PTC-Lisp currently returns the argument."
      ),
      bug_case(
        "core/plus-unary-nonnumeric-bug-001",
        "clojure.core",
        ["+"],
        "(+ [1 2])",
        "GAP-S104",
        "Clojure unary + requires a number; PTC-Lisp currently returns nonnumeric inputs unchanged."
      ),
      bug_case(
        "core/plus-unary-keyword-bug-001",
        "clojure.core",
        ["+"],
        "(+ :a)",
        "GAP-S104",
        "Clojure unary + rejects keyword inputs; PTC-Lisp currently returns them unchanged."
      ),
      bug_case(
        "core/plus-unary-string-bug-001",
        "clojure.core",
        ["+"],
        ~S|(+ "a")|,
        "GAP-S104",
        "Clojure unary + rejects string inputs; PTC-Lisp currently returns them unchanged."
      ),
      bug_case(
        "core/multiply-unary-nonnumeric-bug-001",
        "clojure.core",
        ["*"],
        "(* [1 2])",
        "GAP-S104",
        "Clojure unary * requires a number; PTC-Lisp currently returns nonnumeric inputs unchanged."
      ),
      bug_case(
        "core/multiply-unary-keyword-bug-001",
        "clojure.core",
        ["*"],
        "(* :a)",
        "GAP-S104",
        "Clojure unary * rejects keyword inputs; PTC-Lisp currently returns them unchanged."
      ),
      bug_case(
        "core/divide-unary-nonnumeric-bug-001",
        "clojure.core",
        ["/"],
        "(/ :a)",
        "GAP-S104",
        "Clojure unary / requires a number; PTC-Lisp currently returns nonnumeric inputs unchanged."
      ),
      bug_case(
        "core/set-nil-bug-001",
        "clojure.core",
        ["set"],
        "(set nil)",
        "GAP-S30",
        "Clojure set treats nil as an empty seq; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/set-string-bug-001",
        "clojure.core",
        ["set"],
        ~S|(set "ab")|,
        "GAP-S30",
        "Clojure set accepts seqable strings; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/set-map-bug-001",
        "clojure.core",
        ["set"],
        "(set {:a 1})",
        "GAP-S30",
        "Clojure set accepts maps as seqable map entries; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/union-nil-bug-001",
        "clojure.set",
        ["union"],
        ~S|(clojure.set/union nil #{1})|,
        "GAP-S30",
        "Clojure set union handles nil as an empty collection; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/union-second-nil-bug-001",
        "clojure.set",
        ["union"],
        ~S|(clojure.set/union #{1} nil)|,
        "GAP-S30",
        "Clojure set union handles nil operands in later positions as empty collections; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/intersection-nil-bug-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection nil #{1})|,
        "GAP-S30",
        "Clojure set intersection handles nil as an empty collection; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/intersection-second-nil-bug-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection #{1 2} nil)|,
        "GAP-S30",
        "Clojure set intersection handles nil operands in later positions as empty collections; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/difference-nil-bug-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference nil #{1})|,
        "GAP-S30",
        "Clojure set difference handles nil as an empty collection; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/difference-second-nil-bug-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference #{1 2} nil)|,
        "GAP-S30",
        "Clojure set difference ignores nil collections in later positions; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/union-vector-bug-001",
        "clojure.set",
        ["union"],
        ~S|(clojure.set/union [1 2] #{2 3})|,
        "GAP-S30",
        "Clojure set union accepts finite seqable inputs; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/union-map-bug-001",
        "clojure.set",
        ["union"],
        ~S|(clojure.set/union {:a 1} #{[:b 2]})|,
        "GAP-S30",
        "Clojure set union can conjoin map-entry vectors into a map input; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/intersection-map-bug-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection {:a 1} #{[:a 1]})|,
        "GAP-S30",
        "Clojure set intersection can operate on map entries; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/intersection-vector-first-bug-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection [1 2] #{2})|,
        "GAP-S30",
        "Clojure set intersection accepts finite seqable non-set inputs in the first position; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/intersection-vector-second-bug-001",
        "clojure.set",
        ["intersection"],
        ~S|(clojure.set/intersection #{1 2} [2 3])|,
        "GAP-S30",
        "Clojure set intersection accepts finite seqable non-set inputs in later positions; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/difference-vector-second-bug-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference #{1 2} [2])|,
        "GAP-S30",
        "Clojure set difference accepts finite seqable non-set inputs in later positions; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/union-list-bug-001",
        "clojure.set",
        ["union"],
        ~S|(clojure.set/union (list 1 2) #{2 3})|,
        "GAP-S30",
        "Clojure set union accepts finite list inputs; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/difference-string-second-bug-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference #{"a" "b"} "ab")|,
        "GAP-S30",
        "Clojure set difference accepts finite seqable string operands in later positions; PTC-Lisp currently raises."
      ),
      bug_case(
        "set/difference-map-second-bug-001",
        "clojure.set",
        ["difference"],
        ~S|(clojure.set/difference #{[:a 1]} {:a 1})|,
        "GAP-S30",
        "Clojure set difference accepts finite map-entry operands in later positions; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/partition-nil-pad-bug-001",
        "clojure.core",
        ["partition"],
        "(partition 3 3 nil [1 2])",
        "GAP-S31",
        "Clojure treats a nil padding collection as empty; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/partition-negative-count-bug-001",
        "clojure.core",
        ["partition"],
        "(partition -1 [1 2 3])",
        "GAP-S53",
        "Clojure returns an empty seq for a negative partition size; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/take-negative-bug-001",
        "clojure.core",
        ["take"],
        "(take -1 [1 2])",
        "GAP-S32",
        "Clojure returns an empty seq for negative take counts; PTC-Lisp currently returns the tail."
      ),
      bug_case(
        "core/drop-negative-bug-001",
        "clojure.core",
        ["drop"],
        "(drop -1 [1 2])",
        "GAP-S32",
        "Clojure returns the input for negative drop counts; PTC-Lisp currently drops from the end."
      ),
      bug_case(
        "core/take-last-negative-bug-001",
        "clojure.core",
        ["take-last"],
        "(take-last -1 [1 2])",
        "GAP-S32",
        "Clojure returns nil for negative take-last counts; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/take-last-string-negative-bug-001",
        "clojure.core",
        ["take-last"],
        ~S|(take-last -1 "ab")|,
        "GAP-S32",
        "Clojure returns nil for negative take-last counts on strings too; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/apply-plus-nil-bug-001",
        "clojure.core",
        ["apply"],
        "(apply + nil)",
        "GAP-S33",
        "Clojure treats a nil final apply argument as empty; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/apply-vector-nil-bug-001",
        "clojure.core",
        ["apply"],
        "(apply vector nil)",
        "GAP-S33",
        "Clojure treats a nil final apply argument as empty; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/apply-str-nil-bug-001",
        "clojure.core",
        ["apply"],
        "(apply str nil)",
        "GAP-S33",
        "Clojure treats a nil final apply argument as empty; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/apply-string-final-bug-001",
        "clojure.core",
        ["apply"],
        ~S|(apply str "ab")|,
        "GAP-S33",
        "Clojure treats a string final apply argument as seqable; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/apply-str-prefix-string-final-bug-001",
        "clojure.core",
        ["apply"],
        ~S|(apply str "a" "bc")|,
        "GAP-S33",
        "Clojure treats a string final apply argument as seqable even with leading args; PTC-Lisp currently raises."
      ),
      regression_case(
        "core/apply-nil-function-001",
        "clojure.core",
        ["apply"],
        "(apply nil [1])",
        ["GAP-S109"],
        [:hof]
      ),
      regression_case(
        "core/comp-nil-function-001",
        "clojure.core",
        ["comp"],
        "((comp nil) 1)",
        ["GAP-S135"],
        [:hof]
      ),
      bug_case(
        "core/bit-shift-left-negative-bug-001",
        "clojure.core",
        ["bit-shift-left"],
        "(bit-shift-left 1 -1)",
        "GAP-S52",
        "Clojure accepts negative shift counts using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-shift-right-negative-bug-001",
        "clojure.core",
        ["bit-shift-right"],
        "(bit-shift-right 8 -1)",
        "GAP-S52",
        "Clojure accepts negative shift counts using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-test-negative-index-bug-001",
        "clojure.core",
        ["bit-test"],
        "(bit-test 1 -1)",
        "GAP-S52",
        "Clojure accepts negative bit indexes using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-set-negative-index-bug-001",
        "clojure.core",
        ["bit-set"],
        "(bit-set 1 -1)",
        "GAP-S52",
        "Clojure accepts negative bit indexes using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-clear-negative-index-bug-001",
        "clojure.core",
        ["bit-clear"],
        "(bit-clear 1 -1)",
        "GAP-S52",
        "Clojure accepts negative bit indexes using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-flip-negative-index-bug-001",
        "clojure.core",
        ["bit-flip"],
        "(bit-flip 1 -1)",
        "GAP-S52",
        "Clojure accepts negative bit indexes using JVM shift masking; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/bit-set-large-index-bug-001",
        "clojure.core",
        ["bit-set"],
        "(bit-set 0 64)",
        "GAP-S52",
        "Clojure masks large bit indexes modulo the JVM word width; PTC-Lisp currently treats them as arbitrary precision bit positions."
      ),
      bug_case(
        "core/bit-clear-large-index-bug-001",
        "clojure.core",
        ["bit-clear"],
        "(bit-clear -1 64)",
        "GAP-S52",
        "Clojure masks large bit indexes modulo the JVM word width; PTC-Lisp currently treats them as arbitrary precision bit positions."
      ),
      bug_case(
        "core/bit-test-large-index-bug-001",
        "clojure.core",
        ["bit-test"],
        "(bit-test 1 64)",
        "GAP-S52",
        "Clojure masks large bit indexes modulo the JVM word width; PTC-Lisp currently treats them as arbitrary precision bit positions."
      ),
      bug_case(
        "core/bit-flip-large-index-bug-001",
        "clojure.core",
        ["bit-flip"],
        "(bit-flip 0 64)",
        "GAP-S52",
        "Clojure masks large bit indexes modulo the JVM word width; PTC-Lisp currently treats them as arbitrary precision bit positions."
      ),
      bug_case(
        "core/bit-clear-large-index-present-bug-001",
        "clojure.core",
        ["bit-clear"],
        "(bit-clear 1 64)",
        "GAP-S52",
        "Clojure masks large bit indexes modulo the JVM word width; PTC-Lisp currently treats bit 64 as a separate arbitrary-precision position."
      ),
      bug_case(
        "core/bit-shift-left-large-count-bug-001",
        "clojure.core",
        ["bit-shift-left"],
        "(bit-shift-left 1 64)",
        "GAP-S52",
        "Clojure masks large shift counts modulo the JVM word width; PTC-Lisp currently shifts by the full count."
      ),
      bug_case(
        "core/bit-shift-right-large-count-bug-001",
        "clojure.core",
        ["bit-shift-right"],
        "(bit-shift-right -2 64)",
        "GAP-S52",
        "Clojure masks large shift counts modulo the JVM word width; PTC-Lisp currently shifts by the full count."
      ),
      regression_case(
        "core/bit-and-unary-001",
        "clojure.core",
        ["bit-and"],
        "(bit-and 7)",
        ["GAP-S108"],
        [:numeric]
      ),
      regression_case(
        "core/bit-or-unary-001",
        "clojure.core",
        ["bit-or"],
        "(bit-or 7)",
        ["GAP-S108"],
        [:numeric]
      ),
      regression_case(
        "core/bit-xor-unary-001",
        "clojure.core",
        ["bit-xor"],
        "(bit-xor 7)",
        ["GAP-S108"],
        [:numeric]
      ),
      regression_case(
        "core/bit-and-not-unary-001",
        "clojure.core",
        ["bit-and-not"],
        "(bit-and-not 7)",
        ["GAP-S108"],
        [:numeric]
      ),
      bug_case(
        "core/bit-not-bigint-bug-001",
        "clojure.core",
        ["bit-not"],
        "(bit-not 9223372036854775808)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-and-bigint-bug-001",
        "clojure.core",
        ["bit-and"],
        "(bit-and 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-or-bigint-bug-001",
        "clojure.core",
        ["bit-or"],
        "(bit-or 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-set-bigint-bug-001",
        "clojure.core",
        ["bit-set"],
        "(bit-set 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-test-bigint-bug-001",
        "clojure.core",
        ["bit-test"],
        "(bit-test 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-shift-left-bigint-bug-001",
        "clojure.core",
        ["bit-shift-left"],
        "(bit-shift-left 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-and-not-bigint-bug-001",
        "clojure.core",
        ["bit-and-not"],
        "(bit-and-not 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-xor-bigint-bug-001",
        "clojure.core",
        ["bit-xor"],
        "(bit-xor 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-clear-bigint-bug-001",
        "clojure.core",
        ["bit-clear"],
        "(bit-clear 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-flip-bigint-bug-001",
        "clojure.core",
        ["bit-flip"],
        "(bit-flip 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-shift-right-bigint-bug-001",
        "clojure.core",
        ["bit-shift-right"],
        "(bit-shift-right 9223372036854775808 1)",
        "GAP-S142",
        "Clojure rejects bit operations on BigInt values; PTC-Lisp currently applies arbitrary-precision bit math."
      ),
      bug_case(
        "core/bit-test-bigint-index-bug-001",
        "clojure.core",
        ["bit-test"],
        "(bit-test 1 9223372036854775808)",
        "GAP-S142",
        "Clojure rejects BigInt bit indexes; PTC-Lisp currently accepts them as arbitrary-precision positions."
      ),
      bug_case(
        "core/keyword-two-arity-bug-001",
        "clojure.core",
        ["keyword"],
        ~S|(keyword "ns" "a")|,
        "GAP-S34",
        "Clojure keyword supports namespace/name arity; PTC-Lisp currently only supports one argument."
      ),
      bug_case(
        "core/keyword-call-string-key-bug-001",
        "clojure.core",
        ["keyword"],
        ~S|(:a {"a" 1})|,
        "GAP-S63",
        "Clojure keyword invocation only matches keyword keys; PTC-Lisp currently matches string keys too."
      ),
      bug_case(
        "core/keyword-non-ident-bug-001",
        "clojure.core",
        ["keyword"],
        "(keyword true)",
        "GAP-S78",
        "Clojure keyword returns nil for non-string/non-keyword inputs; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/keyword-number-bug-001",
        "clojure.core",
        ["keyword"],
        "(keyword 1)",
        "GAP-S78",
        "Clojure keyword returns nil for numeric inputs; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/keyword-false-bug-001",
        "clojure.core",
        ["keyword"],
        "(keyword false)",
        "GAP-S78",
        "Clojure keyword returns nil for boolean inputs; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/contains-string-index-bug-001",
        "clojure.core",
        ["contains?"],
        ~S|(contains? "abc" 1)|,
        "GAP-S35",
        "Clojure contains? supports string indexes; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/contains-string-float-index-bug-001",
        "clojure.core",
        ["contains?"],
        ~S|(contains? "abc" 1.0)|,
        "GAP-S35",
        "Clojure contains? supports finite numeric string indexes such as doubles; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/contains-string-out-of-range-bug-001",
        "clojure.core",
        ["contains?"],
        ~S|(contains? "abc" 3)|,
        "GAP-S35",
        "Clojure contains? returns false for out-of-range string indexes; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-set-present-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get #{1 2} 1)|,
        "GAP-S36",
        "Clojure get supports sets by returning the present value; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-set-default-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get #{1 2} 3 :x)|,
        "GAP-S36",
        "Clojure get supports sets and returns the default for a missing value; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-set-present-nil-bug-001",
        "clojure.core",
        ["get"],
        ~S|(get #{nil} nil :x)|,
        "GAP-S36",
        "Clojure get supports set membership even for nil; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-set-present-bug-001",
        "clojure.core",
        ["get-in"],
        ~S|(get-in #{:a} [:a])|,
        "GAP-S36",
        "Clojure get-in supports set roots by returning the present value; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-set-default-bug-001",
        "clojure.core",
        ["get-in"],
        ~S|(get-in #{:a} [:b] :missing)|,
        "GAP-S36",
        "Clojure get-in supports set roots and returns the default for a missing value; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/get-in-set-present-nil-bug-001",
        "clojure.core",
        ["get-in"],
        ~S|(get-in #{nil} [nil] :missing)|,
        "GAP-S36",
        "Clojure get-in supports set membership even for nil; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/case-no-default-bug-001",
        "clojure.core",
        ["case"],
        "(case 3 1 :one 2 :two)",
        "GAP-S37",
        "Clojure raises when case has no matching clause and no default; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/case-duplicate-constant-bug-001",
        "clojure.core",
        ["case"],
        ~S|(case "a" "a" 1 "a" 2)|,
        "GAP-S72",
        "Clojure rejects duplicate case constants; PTC-Lisp currently accepts the first matching clause."
      ),
      bug_case(
        "core/case-vector-constant-bug-001",
        "clojure.core",
        ["case"],
        "(case [1 2] [1 2] :ok :no)",
        "GAP-S72",
        "Clojure case accepts vector constants; PTC-Lisp currently rejects them as non-constant."
      ),
      bug_case(
        "core/case-map-constant-bug-001",
        "clojure.core",
        ["case"],
        "(case {:a 1} {:a 1} :ok :no)",
        "GAP-S72",
        "Clojure case accepts map constants; PTC-Lisp currently rejects them as non-constant."
      ),
      bug_case(
        "core/case-set-constant-bug-001",
        "clojure.core",
        ["case"],
        ~S|(case #{:a} #{:a} :ok :no)|,
        "GAP-S72",
        "Clojure case accepts set constants; PTC-Lisp currently rejects them as non-constant."
      ),
      bug_case(
        "core/case-list-constant-bug-001",
        "clojure.core",
        ["case"],
        "(case (quote a) (a b) :ok :no)",
        "GAP-S72",
        "Clojure case accepts list constants as constant sets; PTC-Lisp currently rejects them as non-constant."
      ),
      regression_case(
        "core/cond-zero-clauses-001",
        "clojure.core",
        ["cond"],
        "(cond)",
        ["GAP-S112"],
        [:control_flow]
      ),
      regression_case(
        "core/when-no-body-001",
        "clojure.core",
        ["when"],
        "(when true)",
        ["GAP-S113"],
        [:control_flow]
      ),
      regression_case(
        "core/when-not-no-body-001",
        "clojure.core",
        ["when-not"],
        "(when-not true)",
        ["GAP-S113"],
        [:control_flow]
      ),
      regression_case(
        "core/let-no-body-001",
        "clojure.core",
        ["let"],
        "(let [x 1])",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/loop-no-body-001",
        "clojure.core",
        ["loop"],
        "(loop [x 1])",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/fn-no-body-001",
        "clojure.core",
        ["fn"],
        "((fn [x]) 1)",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/defn-no-body-001",
        "clojure.core",
        ["defn"],
        "(do (defn f [x]) (f 1))",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/when-let-no-body-001",
        "clojure.core",
        ["when-let"],
        "(when-let [x 1])",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/when-some-no-body-001",
        "clojure.core",
        ["when-some"],
        "(when-some [x false])",
        ["GAP-S114"],
        [:control_flow]
      ),
      regression_case(
        "core/when-first-no-body-001",
        "clojure.core",
        ["when-first"],
        "(when-first [x [1 2]])",
        ["GAP-S114"],
        [:control_flow]
      ),
      bug_case(
        "core/if-let-extra-binding-bug-001",
        "clojure.core",
        ["if-let"],
        "(if-let [x 1 y] x :no)",
        "GAP-S145",
        "Clojure if-let ignores extra binding-vector forms after the first pair; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/if-some-extra-binding-bug-001",
        "clojure.core",
        ["if-some"],
        "(if-some [x false y] x :no)",
        "GAP-S145",
        "Clojure if-some ignores extra binding-vector forms after the first pair; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/when-let-extra-binding-bug-001",
        "clojure.core",
        ["when-let"],
        "(when-let [x 1 y] x)",
        "GAP-S145",
        "Clojure when-let ignores extra binding-vector forms after the first pair; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/when-some-extra-binding-bug-001",
        "clojure.core",
        ["when-some"],
        "(when-some [x false y] x)",
        "GAP-S145",
        "Clojure when-some ignores extra binding-vector forms after the first pair; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/when-first-extra-binding-bug-001",
        "clojure.core",
        ["when-first"],
        "(when-first [x [1] y] x)",
        "GAP-S145",
        "Clojure when-first ignores extra binding-vector forms after the first pair; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/def-no-init-bug-001",
        "clojure.core",
        ["def"],
        "(def no_init_probe)",
        "GAP-S140",
        "Clojure no-init def creates an unbound var; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/def-return-var-namespace-bug-001",
        "clojure.core",
        ["def"],
        "(def return_var_probe 1)",
        "GAP-S141",
        "Clojure def returns a namespace-qualified var; PTC-Lisp currently returns an unqualified var reference."
      ),
      bug_case(
        "core/defonce-return-var-namespace-bug-001",
        "clojure.core",
        ["defonce"],
        "(defonce return_once_var_probe 1)",
        "GAP-S141",
        "Clojure defonce returns a namespace-qualified var; PTC-Lisp currently returns an unqualified var reference."
      ),
      bug_case(
        "core/cond-thread-dangling-test-bug-001",
        "clojure.core",
        ["cond->"],
        "(cond-> 1 true)",
        "GAP-S123",
        "Clojure cond-> treats a trailing unmatched test as a no-op; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/cond-thread-last-dangling-test-bug-001",
        "clojure.core",
        ["cond->>"],
        "(cond->> [1] false)",
        "GAP-S123",
        "Clojure cond->> treats a trailing unmatched test as a no-op; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/thread-first-nil-form-bug-001",
        "clojure.core",
        ["->"],
        "(-> 1 nil)",
        "GAP-S128",
        "Clojure threading through nil raises; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/thread-last-nil-form-bug-001",
        "clojure.core",
        ["->>"],
        "(->> 1 nil)",
        "GAP-S128",
        "Clojure threading through nil raises; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/some-thread-nil-form-bug-001",
        "clojure.core",
        ["some->"],
        "(some-> 1 nil)",
        "GAP-S128",
        "Clojure some-> threading through a nil form raises once the value is non-nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/some-thread-last-nil-form-bug-001",
        "clojure.core",
        ["some->>"],
        "(some->> 1 nil)",
        "GAP-S128",
        "Clojure some->> threading through a nil form raises once the value is non-nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/cond-thread-true-nil-form-bug-001",
        "clojure.core",
        ["cond->"],
        "(cond-> 1 true nil)",
        "GAP-S128",
        "Clojure cond-> threading through a nil form raises when the condition is truthy; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/cond-thread-last-true-nil-form-bug-001",
        "clojure.core",
        ["cond->>"],
        "(cond->> 1 true nil)",
        "GAP-S128",
        "Clojure cond->> threading through a nil form raises when the condition is truthy; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/if-let-no-else-bug-001",
        "clojure.core",
        ["if-let"],
        "(if-let [x nil] :yes)",
        "GAP-S115",
        "Clojure if-let supports a no-else arity returning nil on a falsey test; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/if-let-no-else-truthy-bug-001",
        "clojure.core",
        ["if-let"],
        "(if-let [x 1] :yes)",
        "GAP-S115",
        "Clojure if-let no-else arity evaluates the then branch on a truthy test; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/if-some-no-else-bug-001",
        "clojure.core",
        ["if-some"],
        "(if-some [x false] :yes)",
        "GAP-S115",
        "Clojure if-some supports a no-else arity; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/if-some-no-else-nil-bug-001",
        "clojure.core",
        ["if-some"],
        "(if-some [x nil] :yes)",
        "GAP-S115",
        "Clojure if-some no-else arity returns nil for nil tests; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/condp-result-fn-bug-001",
        "clojure.core",
        ["condp"],
        "(condp = 2 1 :one 2 :>> (fn [x] [:hit x]) :other)",
        "GAP-S38",
        "Clojure condp supports :>> result functions; PTC-Lisp currently rejects the form."
      ),
      bug_case(
        "core/condp-no-default-bug-001",
        "clojure.core",
        ["condp"],
        "(condp = 3 1 :one 2 :two)",
        "GAP-S103",
        "Clojure raises when condp has no matching clause and no default; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/vector-destructuring-as-bug-001",
        "clojure.core",
        ["let"],
        "(let [[a b :as xs] [1 2 3]] [a b xs])",
        "GAP-S39",
        "Clojure vector destructuring supports :as; PTC-Lisp currently rejects the pattern."
      ),
      bug_case(
        "core/fn-vector-destructuring-as-bug-001",
        "clojure.core",
        ["fn"],
        "((fn [[a b :as xs]] xs) [1 2])",
        "GAP-S39",
        "Clojure vector destructuring supports :as in function parameters; PTC-Lisp currently rejects the pattern."
      ),
      bug_case(
        "core/vector-rest-destructuring-as-bug-001",
        "clojure.core",
        ["let"],
        "(let [[a & more :as xs] [1 2 3]] [more xs])",
        "GAP-S39",
        "Clojure vector destructuring supports :as after a rest binding; PTC-Lisp currently rejects the pattern."
      ),
      bug_case(
        "core/map-destructuring-syms-bug-001",
        "clojure.core",
        ["let"],
        ~S|(let [{:syms [a]} {(quote a) 1}] a)|,
        "GAP-S86",
        "Clojure map destructuring supports :syms; PTC-Lisp currently rejects the pattern."
      ),
      bug_case(
        "core/fn-map-destructuring-syms-bug-001",
        "clojure.core",
        ["fn"],
        ~S|((fn [{:syms [a]}] a) {(quote a) 1})|,
        "GAP-S86",
        "Clojure map destructuring supports :syms in function parameters; PTC-Lisp currently rejects the pattern."
      ),
      bug_case(
        "core/map-destructuring-vector-source-bug-001",
        "clojure.core",
        ["let"],
        "(let [{a 0 b 1} [10 20]] [a b])",
        "GAP-S118",
        "Clojure map destructuring uses associative lookup and supports vector sources; PTC-Lisp currently rejects numeric source keys."
      ),
      bug_case(
        "core/fn-map-destructuring-vector-source-bug-001",
        "clojure.core",
        ["fn"],
        "((fn [{a 0 b 1}] [a b]) [10 20])",
        "GAP-S118",
        "Clojure map destructuring uses associative lookup for vector sources in function parameters; PTC-Lisp currently rejects numeric source keys."
      ),
      bug_case(
        "core/defn-map-destructuring-vector-source-bug-001",
        "clojure.core",
        ["defn"],
        "(do (defn f [{a 0 b 1}] [a b]) (f [10 20]))",
        "GAP-S118",
        "Clojure map destructuring uses associative lookup for vector sources in defn parameters; PTC-Lisp currently rejects numeric source keys."
      ),
      bug_case(
        "core/vector-destructuring-string-bug-001",
        "clojure.core",
        ["let"],
        ~S|(let [[a b] "xy"] [a b])|,
        "GAP-S87",
        "Clojure vector destructuring treats strings as seqable; PTC-Lisp currently rejects string inputs."
      ),
      bug_case(
        "core/vector-rest-destructuring-string-bug-001",
        "clojure.core",
        ["let"],
        ~S|(let [[a b & more] "xyz"] [a b more])|,
        "GAP-S87",
        "Clojure vector/rest destructuring treats strings as seqable; PTC-Lisp currently rejects string inputs."
      ),
      bug_case(
        "core/fn-vector-destructuring-string-bug-001",
        "clojure.core",
        ["fn"],
        ~S|((fn [[a b]] [a b]) "xy")|,
        "GAP-S87",
        "Clojure vector destructuring treats strings as seqable in function parameters; PTC-Lisp currently rejects string inputs."
      ),
      bug_case(
        "core/fn-vector-rest-destructuring-string-bug-001",
        "clojure.core",
        ["fn"],
        ~S|((fn [[a b & more]] [a b more]) "xyz")|,
        "GAP-S87",
        "Clojure vector/rest destructuring treats strings as seqable in function parameters; PTC-Lisp currently rejects string inputs."
      ),
      bug_case(
        "core/vector-rest-destructuring-nil-bug-001",
        "clojure.core",
        ["let"],
        "(let [[a b & more] nil] [a b more])",
        "GAP-S97",
        "Clojure vector rest destructuring binds the rest name to nil for nil input; PTC-Lisp currently binds an empty vector."
      ),
      bug_case(
        "core/fn-vector-rest-destructuring-nil-bug-001",
        "clojure.core",
        ["fn"],
        "((fn [[a b & more]] [a b more]) nil)",
        "GAP-S97",
        "Clojure vector rest destructuring binds the rest name to nil for nil input in function parameters; PTC-Lisp currently binds an empty vector."
      ),
      bug_case(
        "core/vector-only-rest-destructuring-nil-bug-001",
        "clojure.core",
        ["let"],
        "(let [[& more] nil] more)",
        "GAP-S97",
        "Clojure vector rest destructuring binds even an only-rest pattern to nil for nil input; PTC-Lisp currently binds an empty vector."
      ),
      bug_case(
        "core/vector-rest-map-destructuring-bug-001",
        "clojure.core",
        ["let"],
        "(let [[a & {:keys [b]}] [1 :b 2]] [a b])",
        "GAP-S119",
        "Clojure vector rest map destructuring coerces flat key/value rest pairs to a map; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/fn-vector-rest-map-destructuring-bug-001",
        "clojure.core",
        ["fn"],
        "((fn [[a & {:keys [b]}]] [a b]) [1 :b 2])",
        "GAP-S119",
        "Clojure vector rest map destructuring coerces flat key/value rest pairs in function parameters; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/defn-vector-rest-map-destructuring-bug-001",
        "clojure.core",
        ["defn"],
        "(do (defn f [[a & {:keys [b]}]] [a b]) (f [1 :b 2]))",
        "GAP-S119",
        "Clojure vector rest map destructuring coerces flat key/value rest pairs in defn parameters; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/vec-nil-bug-001",
        "clojure.core",
        ["vec"],
        "(vec nil)",
        "GAP-S40",
        "Clojure vec treats nil as an empty collection; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "core/into-set-string-bug-001",
        "clojure.core",
        ["into"],
        ~S|(into #{} "ab")|,
        "GAP-S41",
        "Clojure into accepts seqable strings as sources; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/into-nil-target-bug-001",
        "clojure.core",
        ["into"],
        "(into nil [1 2])",
        "GAP-S41",
        "Clojure into treats nil target as an empty list; PTC-Lisp currently rejects nil targets."
      ),
      bug_case(
        "core/into-zero-arity-bug-001",
        "clojure.core",
        ["into"],
        "(into)",
        "GAP-S41",
        "Clojure zero-arity into returns an empty vector; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/into-one-arity-bug-001",
        "clojure.core",
        ["into"],
        "(into [])",
        "GAP-S41",
        "Clojure one-arity into returns its target collection; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/fnil-two-defaults-bug-001",
        "clojure.core",
        ["fnil"],
        "((fnil + 10 20) nil nil)",
        "GAP-S42",
        "Clojure fnil supports defaults for the first two arguments; PTC-Lisp currently rejects the arity."
      ),
      bug_case(
        "core/fnil-three-defaults-bug-001",
        "clojure.core",
        ["fnil"],
        "((fnil vector 1 2 3) nil nil nil)",
        "GAP-S42",
        "Clojure fnil supports defaults for the first three arguments; PTC-Lisp currently rejects the arity."
      ),
      bug_case(
        "core/select-keys-vector-bug-001",
        "clojure.core",
        ["select-keys"],
        "(select-keys [10 20] [0 1])",
        "GAP-S43",
        "Clojure select-keys can select numeric indexes from vectors; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/char-predicate-string-bug-001",
        "clojure.core",
        ["char?"],
        ~S|(char? "a")|,
        "GAP-S44",
        "Clojure strings are not Character values; PTC-Lisp currently treats a one-character string as char?."
      ),
      bug_case(
        "core/equality-char-string-bug-001",
        "clojure.core",
        ["="],
        ~S|(= \a "a")|,
        "GAP-S120",
        "Clojure Character and String values are not equal; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/equality-char-string-multi-bug-001",
        "clojure.core",
        ["="],
        ~S|(= \a "a" \a)|,
        "GAP-S120",
        "Clojure multi-arity equality still distinguishes Character and String values; PTC-Lisp currently treats them as equal."
      ),
      bug_case(
        "core/not-equality-char-string-bug-001",
        "clojure.core",
        ["not="],
        ~S|(not= \a "a")|,
        "GAP-S120",
        "Clojure Character and String values are not equal; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/numeric-equality-char-string-bug-001",
        "clojure.core",
        ["=="],
        ~S|(== \a "a")|,
        "GAP-S120",
        "Clojure numeric equality rejects Character/String operands; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/case-char-string-bug-001",
        "clojure.core",
        ["case"],
        ~S|(case \a "a" :string :char)|,
        "GAP-S120",
        "Clojure case dispatch distinguishes Character and String constants; PTC-Lisp currently treats them as equal."
      ),
      bug_case(
        "core/seqable-char-bug-001",
        "clojure.core",
        ["seqable?"],
        ~S|(seqable? \a)|,
        "GAP-S125",
        "Clojure Character values are not seqable; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/string-predicate-char-bug-001",
        "clojure.core",
        ["string?"],
        ~S|(string? \a)|,
        "GAP-S133",
        "Clojure Character values are not strings; PTC-Lisp currently treats character literals as one-character strings."
      ),
      bug_case(
        "core/range-zero-step-bug-001",
        "clojure.core",
        ["range", "take"],
        "(take 3 (range 1 5 0))",
        "GAP-S45",
        "Clojure zero-step range repeats the start value under bounded take; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/range-nil-end-bug-001",
        "clojure.core",
        ["range"],
        "(range nil)",
        "GAP-S99",
        "Clojure raises for nil range bounds; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/range-nil-start-bug-001",
        "clojure.core",
        ["range"],
        "(range nil 5)",
        "GAP-S99",
        "Clojure raises for nil range bounds; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/range-nil-stop-bug-001",
        "clojure.core",
        ["range"],
        "(range 1 nil)",
        "GAP-S99",
        "Clojure raises for nil range bounds; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/range-nil-step-bug-001",
        "clojure.core",
        ["range"],
        "(range 1 5 nil)",
        "GAP-S99",
        "Clojure raises for a nil range step; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/range-string-start-bug-001",
        "clojure.core",
        ["range"],
        ~S|(range "1" 3)|,
        "GAP-S99",
        "Clojure raises for nonnumeric range bounds; PTC-Lisp currently returns an empty vector."
      ),
      bug_case(
        "core/sort-nil-comparator-bug-001",
        "clojure.core",
        ["sort"],
        "(sort nil [2 1])",
        "GAP-S46",
        "Clojure treats nil comparator as default compare; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/sort-boolean-comparator-bug-001",
        "clojure.core",
        ["sort"],
        "(sort (fn [a b] false) [3 1 2])",
        "GAP-S107",
        "Clojure boolean comparator functions are valid sort comparators; PTC-Lisp currently reorders as if using its default ordering."
      ),
      bug_case(
        "core/sort-by-boolean-comparator-bug-001",
        "clojure.core",
        ["sort-by"],
        "(sort-by identity (fn [a b] false) [2 1])",
        "GAP-S107",
        "Clojure sort-by accepts boolean comparator functions; PTC-Lisp currently reorders as if using its default ordering."
      ),
      bug_case(
        "core/min-key-tie-bug-001",
        "clojure.core",
        ["min-key"],
        ~S|(min-key count "a" "bb" "c")|,
        "GAP-S47",
        "Clojure min-key returns the last minimum on ties; PTC-Lisp currently returns the first."
      ),
      bug_case(
        "core/min-key-all-tie-bug-001",
        "clojure.core",
        ["min-key"],
        ~S|(min-key count "a" "b" "c")|,
        "GAP-S47",
        "Clojure min-key returns the last value when all keys tie; PTC-Lisp currently returns the first."
      ),
      bug_case(
        "core/max-key-tie-bug-001",
        "clojure.core",
        ["max-key"],
        ~S|(max-key count "aa" "bb" "c")|,
        "GAP-S47",
        "Clojure max-key returns the last maximum on ties; PTC-Lisp currently returns the first."
      ),
      bug_case(
        "core/max-key-all-tie-bug-001",
        "clojure.core",
        ["max-key"],
        ~S|(max-key count "a" "b" "c")|,
        "GAP-S47",
        "Clojure max-key returns the last value when all keys tie; PTC-Lisp currently returns the first."
      ),
      regression_case(
        "core/last-nil-001",
        "clojure.core",
        ["last"],
        "(last nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/butlast-nil-001",
        "clojure.core",
        ["butlast"],
        "(butlast nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/butlast-empty-001",
        "clojure.core",
        ["butlast"],
        "(butlast [])",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/butlast-singleton-001",
        "clojure.core",
        ["butlast"],
        "(butlast [1])",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/butlast-empty-string-001",
        "clojure.core",
        ["butlast"],
        ~S|(butlast "")|,
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/butlast-singleton-string-001",
        "clojure.core",
        ["butlast"],
        ~S|(butlast "a")|,
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/take-last-nil-001",
        "clojure.core",
        ["take-last"],
        "(take-last 2 nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/ffirst-nil-001",
        "clojure.core",
        ["ffirst"],
        "(ffirst nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/fnext-nil-001",
        "clojure.core",
        ["fnext"],
        "(fnext nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/nfirst-nil-001",
        "clojure.core",
        ["nfirst"],
        "(nfirst nil)",
        ["GAP-S48"],
        [:collection]
      ),
      regression_case(
        "core/nnext-nil-001",
        "clojure.core",
        ["nnext"],
        "(nnext nil)",
        ["GAP-S48"],
        [:collection]
      ),
      bug_case(
        "core/mapcat-two-colls-bug-001",
        "clojure.core",
        ["mapcat"],
        "(mapcat vector [1 2] [:a :b])",
        "GAP-S49",
        "Clojure mapcat supports multiple input collections; PTC-Lisp currently rejects the arity."
      ),
      bug_case(
        "core/mapcat-string-result-bug-001",
        "clojure.core",
        ["mapcat"],
        ~S|(mapcat identity ["ab" "c"])|,
        "GAP-S49",
        "Clojure mapcat concatenates seqable string results; PTC-Lisp currently raises."
      ),
      bug_case(
        "core/mapcat-nil-result-bug-001",
        "clojure.core",
        ["mapcat"],
        "(mapcat (fn [x] nil) [1 2])",
        "GAP-S49",
        "Clojure mapcat treats nil mapping results as empty seqs; PTC-Lisp currently raises."
      )
    ]
  end

  defp candidate_unsupported_cases do
    [
      unsupported_case(
        "candidate/string-capitalize-001",
        "clojure.string",
        ["capitalize"],
        ~S|(clojure.string/capitalize "abc")|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/string-replace-first-001",
        "clojure.string",
        ["replace-first"],
        ~S|(clojure.string/replace-first "ababa" "ba" "X")|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/string-escape-001",
        "clojure.string",
        ["escape"],
        ~S|(clojure.string/escape "a&b" {\& "&amp;"})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/string-reverse-001",
        "clojure.string",
        ["reverse"],
        ~S|(clojure.string/reverse "abc")|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-map-invert-001",
        "clojure.set",
        ["map-invert"],
        "(clojure.set/map-invert {:a 1 :b 2})",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-rename-keys-001",
        "clojure.set",
        ["rename-keys"],
        "(clojure.set/rename-keys {:a 1 :b 2} {:a :x})",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-select-001",
        "clojure.set",
        ["select"],
        ~S|(clojure.set/select odd? #{1 2 3})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-subset-001",
        "clojure.set",
        ["subset?"],
        ~S|(clojure.set/subset? #{1} #{1 2})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-superset-001",
        "clojure.set",
        ["superset?"],
        ~S|(clojure.set/superset? #{1 2} #{1})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-project-001",
        "clojure.set",
        ["project"],
        ~S|(clojure.set/project #{{:a 1 :b 2} {:a 3 :b 4}} [:a])|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-rename-001",
        "clojure.set",
        ["rename"],
        ~S|(clojure.set/rename #{{:a 1}} {:a :x})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/walk-keywordize-keys-001",
        "clojure.walk",
        ["keywordize-keys"],
        ~S|(clojure.walk/keywordize-keys {"a" 1})|,
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/walk-stringify-keys-001",
        "clojure.walk",
        ["stringify-keys"],
        "(clojure.walk/stringify-keys {:a 1})",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/walk-prewalk-replace-001",
        "clojure.walk",
        ["prewalk-replace"],
        "(clojure.walk/prewalk-replace {:a :x} [:a])",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/walk-postwalk-replace-001",
        "clojure.walk",
        ["postwalk-replace"],
        "(clojure.walk/postwalk-replace {:a :x} [:a])",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-any-001",
        "clojure.core",
        ["any?"],
        "(any? nil)",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-sorted-map-001",
        "clojure.core",
        ["sorted-map"],
        "(sorted-map :b 2 :a 1)",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-sorted-set-001",
        "clojure.core",
        ["sorted-set"],
        "(sorted-set 3 1 2)",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-symbol-001",
        "clojure.core",
        ["symbol"],
        ~S|(symbol "a")|,
        "Symbols are outside the PTC-Lisp data model."
      ),
      unsupported_case(
        "candidate/core-reduced-001",
        "clojure.core",
        ["reduced"],
        "(reduced 1)",
        "Reduction control wrapper not currently implemented."
      ),
      unsupported_case(
        "candidate/core-comparator-001",
        "clojure.core",
        ["comparator"],
        "((comparator <) 1 2)",
        "Pure candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-completing-001",
        "clojure.core",
        ["completing"],
        "((completing conj) [1] 2)",
        "Reduction/transducer helper not currently implemented."
      ),
      unsupported_case(
        "candidate/core-ensure-reduced-001",
        "clojure.core",
        ["ensure-reduced"],
        "(reduced? (ensure-reduced 1))",
        "Reduction control wrapper not currently implemented."
      ),
      unsupported_case(
        "candidate/core-sorted-map-by-001",
        "clojure.core",
        ["sorted-map-by"],
        "(sorted-map-by compare :b 2 :a 1)",
        "Sorted map with comparator not currently implemented."
      ),
      unsupported_case(
        "candidate/core-sorted-set-by-001",
        "clojure.core",
        ["sorted-set-by"],
        "(sorted-set-by > 1 3 2)",
        "Sorted set with comparator not currently implemented."
      ),
      unsupported_case(
        "candidate/core-subseq-001",
        "clojure.core",
        ["subseq"],
        "(subseq (sorted-set 1 2 3) > 1)",
        "Sorted collection subsequence helper not currently implemented."
      ),
      unsupported_case(
        "candidate/set-index-001",
        "clojure.set",
        ["index"],
        ~S|(clojure.set/index #{{:a 1 :b 2} {:a 1 :b 3}} [:a])|,
        "Relational set candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/set-join-001",
        "clojure.set",
        ["join"],
        ~S|(clojure.set/join #{{:a 1 :b 2}} #{{:a 1 :c 3}})|,
        "Relational set candidate not currently implemented."
      ),
      unsupported_case(
        "candidate/core-reduced-predicate-001",
        "clojure.core",
        ["reduced?"],
        "(reduced? (reduced 1))",
        "Reduction control wrapper not currently implemented."
      ),
      unsupported_case(
        "candidate/core-unreduced-001",
        "clojure.core",
        ["unreduced"],
        "(unreduced (reduced 1))",
        "Reduction control wrapper not currently implemented."
      )
    ]
  end

  defp java_candidate_unsupported_cases do
    [
      unsupported_case(
        "candidate/java-boolean-value-of-001",
        "java.lang.Boolean",
        ["Boolean/valueOf"],
        ~S|(Boolean/valueOf "true")|,
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-boolean-true-001",
        "java.lang.Boolean",
        ["Boolean/TRUE"],
        "Boolean/TRUE",
        "Java constant candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-boolean-false-001",
        "java.lang.Boolean",
        ["Boolean/FALSE"],
        "Boolean/FALSE",
        "Java constant candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-double-is-nan-001",
        "java.lang.Double",
        ["Double/isNaN"],
        "(Double/isNaN ##NaN)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-double-is-infinite-001",
        "java.lang.Double",
        ["Double/isInfinite"],
        "(Double/isInfinite ##Inf)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-double-value-of-001",
        "java.lang.Double",
        ["Double/valueOf"],
        ~S|(Double/valueOf "1.5")|,
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-float-is-nan-001",
        "java.lang.Float",
        ["Float/isNaN"],
        "(Float/isNaN ##NaN)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-float-is-infinite-001",
        "java.lang.Float",
        ["Float/isInfinite"],
        "(Float/isInfinite ##Inf)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-float-value-of-001",
        "java.lang.Float",
        ["Float/valueOf"],
        ~S|(Float/valueOf "1.5")|,
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-integer-value-of-001",
        "java.lang.Integer",
        ["Integer/valueOf"],
        ~S|(Integer/valueOf "42")|,
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-integer-to-string-001",
        "java.lang.Integer",
        ["Integer/toString"],
        "(Integer/toString 42)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-long-value-of-001",
        "java.lang.Long",
        ["Long/valueOf"],
        ~S|(Long/valueOf "42")|,
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-long-to-string-001",
        "java.lang.Long",
        ["Long/toString"],
        "(Long/toString 42)",
        "Java candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-string-trim-001",
        "java.lang.String",
        [".trim"],
        ~S|(.trim " abc ")|,
        "Java string candidate outside the current minimal interop surface; use clojure.string/trim."
      ),
      unsupported_case(
        "candidate/java-string-is-empty-001",
        "java.lang.String",
        [".isEmpty"],
        ~S|(.isEmpty "")|,
        "Java string candidate outside the current minimal interop surface; use empty?."
      ),
      unsupported_case(
        "candidate/java-string-equals-ignore-case-001",
        "java.lang.String",
        [".equalsIgnoreCase"],
        ~S|(.equalsIgnoreCase "AbC" "abc")|,
        "Java string candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-string-char-at-001",
        "java.lang.String",
        [".charAt"],
        ~S|(.charAt "abc" 1)|,
        "Java string candidate outside the current minimal interop surface; use nth for string indexing."
      ),
      unsupported_case(
        "candidate/java-system-nano-time-001",
        "java.lang.System",
        ["System/nanoTime"],
        "(System/nanoTime)",
        "Non-deterministic high-resolution time is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-duration-of-millis-001",
        "java.time.Duration",
        ["Duration/ofMillis"],
        "(java.time.Duration/ofMillis 1000)",
        "Java duration constructor candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-duration-parse-001",
        "java.time.Duration",
        ["Duration/parse"],
        ~S|(java.time.Duration/parse "PT1S")|,
        "Java duration parser candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-instant-now-001",
        "java.time.Instant",
        ["Instant/now"],
        "(java.time.Instant/now)",
        "Non-deterministic current time constructor is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-instant-of-epoch-milli-001",
        "java.time.Instant",
        ["Instant/ofEpochMilli"],
        "(java.time.Instant/ofEpochMilli 1000)",
        "Java instant constructor candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-local-date-now-001",
        "java.time.LocalDate",
        ["LocalDate/now"],
        "(java.time.LocalDate/now)",
        "Non-deterministic current date constructor is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-local-date-of-001",
        "java.time.LocalDate",
        ["LocalDate/of"],
        "(java.time.LocalDate/of 2020 1 2)",
        "Java local date constructor candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-local-date-format-001",
        "java.time.LocalDate",
        [".format"],
        ~S|(.format (java.time.LocalDate/parse "2020-01-02") "yyyy")|,
        "Java formatter interop is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-period-between-001",
        "java.time.Period",
        ["Period/between"],
        ~S|(java.time.Period/between (java.time.LocalDate/parse "2020-01-01") (java.time.LocalDate/parse "2020-01-03"))|,
        "java.time.Period is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-period-get-days-001",
        "java.time.Period",
        [".getDays"],
        ~S|(.getDays (java.time.Period/between (java.time.LocalDate/parse "2020-01-01") (java.time.LocalDate/parse "2020-01-03")))|,
        "java.time.Period is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-period-of-days-001",
        "java.time.Period",
        ["Period/ofDays"],
        "(java.time.Period/ofDays 2)",
        "java.time.Period is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-period-parse-001",
        "java.time.Period",
        ["Period/parse"],
        ~S|(java.time.Period/parse "P2D")|,
        "java.time.Period is outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-date-before-001",
        "java.util.Date",
        [".before"],
        "(.before (java.util.Date. 0) (java.util.Date. 1000))",
        "Java Date comparison candidate outside the current minimal interop surface."
      ),
      unsupported_case(
        "candidate/java-date-after-001",
        "java.util.Date",
        [".after"],
        "(.after (java.util.Date. 1000) (java.util.Date. 0))",
        "Java Date comparison candidate outside the current minimal interop surface."
      )
    ]
  end

  defp java_match_cases do
    [
      c(
        "java/string-contains-001",
        "java.lang.String",
        [".contains"],
        ~S|(.contains "abcdef" "bcd")|,
        [
          :java,
          :string
        ]
      ),
      c(
        "java/string-index-of-001",
        "java.lang.String",
        [".indexOf"],
        ~S|(.indexOf "abcdef" "cd")|,
        [
          :java,
          :string
        ]
      ),
      c(
        "java/string-last-index-of-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "ababa" "ba")|,
        [:java, :string]
      ),
      c("java/string-length-001", "java.lang.String", [".length"], ~S|(.length "abc")|, [
        :java,
        :string
      ]),
      c(
        "java/string-substring-001",
        "java.lang.String",
        [".substring"],
        ~S|(.substring "abcdef" 1 4)|,
        [:java, :string]
      ),
      c(
        "java/string-lower-001",
        "java.lang.String",
        [".toLowerCase"],
        ~S|(.toLowerCase "AbC")|,
        [:java, :string]
      ),
      c(
        "java/string-upper-001",
        "java.lang.String",
        [".toUpperCase"],
        ~S|(.toUpperCase "AbC")|,
        [:java, :string]
      ),
      c(
        "java/string-starts-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abcdef" "abc")|,
        [:java, :string]
      ),
      c(
        "java/string-ends-001",
        "java.lang.String",
        [".endsWith"],
        ~S|(.endsWith "abcdef" "def")|,
        [:java, :string]
      ),
      c(
        "java/double-positive-infinity-001",
        "java.lang.Double",
        ["Double/POSITIVE_INFINITY"],
        "Double/POSITIVE_INFINITY",
        [:java, :numeric]
      ),
      c(
        "java/double-negative-infinity-001",
        "java.lang.Double",
        ["Double/NEGATIVE_INFINITY"],
        "Double/NEGATIVE_INFINITY",
        [:java, :numeric]
      ),
      c("java/double-nan-001", "java.lang.Double", ["Double/NaN"], "Double/NaN", [
        :java,
        :numeric
      ]),
      c(
        "java/local-date-to-epoch-day-001",
        "java.time.LocalDate",
        ["LocalDate/parse", ".toEpochDay"],
        ~S|(.toEpochDay (java.time.LocalDate/parse "2024-01-02"))|,
        [:java]
      ),
      c(
        "java/local-date-plus-days-001",
        "java.time.LocalDate",
        [".plusDays"],
        ~S|(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-02") 2))|,
        [:java]
      ),
      c(
        "java/local-date-minus-days-001",
        "java.time.LocalDate",
        [".minusDays"],
        ~S|(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-02") 2))|,
        [:java]
      ),
      c(
        "java/local-date-is-before-001",
        "java.time.LocalDate",
        [".isBefore"],
        ~S|(.isBefore (java.time.LocalDate/parse "2024-01-02") (java.time.LocalDate/parse "2024-01-03"))|,
        [:java]
      ),
      c(
        "java/local-date-is-after-001",
        "java.time.LocalDate",
        [".isAfter"],
        ~S|(.isAfter (java.time.LocalDate/parse "2024-01-02") (java.time.LocalDate/parse "2024-01-03"))|,
        [:java]
      ),
      c(
        "java/instant-is-before-001",
        "java.time.Instant",
        ["Instant/parse", ".isBefore"],
        ~S|(.isBefore (java.time.Instant/parse "1970-01-01T00:00:01Z") (java.time.Instant/parse "1970-01-01T00:00:02Z"))|,
        [:java]
      ),
      c(
        "java/instant-is-after-001",
        "java.time.Instant",
        [".isAfter"],
        ~S|(.isAfter (java.time.Instant/parse "1970-01-01T00:00:01Z") (java.time.Instant/parse "1970-01-01T00:00:02Z"))|,
        [:java]
      ),
      c(
        "java/duration-to-millis-001",
        "java.time.Duration",
        ["Duration/between", ".toMillis"],
        ~S|(.toMillis (java.time.Duration/between (java.time.Instant/parse "1970-01-01T00:00:01Z") (java.time.Instant/parse "1970-01-01T00:00:03Z")))|,
        [:java]
      ),
      c(
        "java/duration-to-days-001",
        "java.time.Duration",
        [".toDays"],
        ~S|(.toDays (java.time.Duration/between (java.time.Instant/parse "1970-01-01T00:00:00Z") (java.time.Instant/parse "1970-01-03T00:00:00Z")))|,
        [:java]
      ),
      c(
        "java/system-current-time-millis-001",
        "java.lang.System",
        ["System/currentTimeMillis"],
        "(integer? (System/currentTimeMillis))",
        [:java]
      )
    ]
  end

  defp java_bug_cases do
    [
      bug_case(
        "java/integer-parse-int-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "x")|,
        "GAP-J01",
        "Java parseInt raises NumberFormatException, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/integer-parse-int-empty-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "")|,
        "GAP-J01",
        "Java parseInt raises NumberFormatException for an empty string, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/integer-parse-int-whitespace-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt " 1")|,
        "GAP-J01",
        "Java parseInt rejects leading whitespace, but PTC-Lisp currently returns nil instead of raising."
      ),
      bug_case(
        "java/integer-parse-int-overflow-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "2147483648")|,
        "GAP-J01",
        "Java parseInt raises NumberFormatException for values above Integer/MAX_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/integer-parse-int-plus-overflow-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "+2147483648")|,
        "GAP-J01",
        "Java parseInt raises NumberFormatException for signed values above Integer/MAX_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/integer-parse-int-underflow-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "-2147483649")|,
        "GAP-J01",
        "Java parseInt raises NumberFormatException for values below Integer/MIN_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/integer-parse-int-nil-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        "(Integer/parseInt nil)",
        "GAP-J01",
        "Java parseInt raises NumberFormatException for nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/integer-parse-int-radix-bug-001",
        "java.lang.Integer",
        ["Integer/parseInt"],
        ~S|(Integer/parseInt "10" 16)|,
        "GAP-J15",
        "Java parseInt supports a radix overload; PTC-Lisp currently raises an arity error."
      ),
      bug_case(
        "java/long-parse-long-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "x")|,
        "GAP-J01",
        "Java parseLong raises NumberFormatException, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/long-parse-long-empty-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "")|,
        "GAP-J01",
        "Java parseLong raises NumberFormatException for an empty string, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/long-parse-long-whitespace-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong " 1")|,
        "GAP-J01",
        "Java parseLong rejects leading whitespace, but PTC-Lisp currently returns nil instead of raising."
      ),
      bug_case(
        "java/long-parse-long-overflow-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "9223372036854775808")|,
        "GAP-J01",
        "Java parseLong raises NumberFormatException for values above Long/MAX_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/long-parse-long-plus-overflow-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "+9223372036854775808")|,
        "GAP-J01",
        "Java parseLong raises NumberFormatException for signed values above Long/MAX_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/long-parse-long-underflow-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "-9223372036854775809")|,
        "GAP-J01",
        "Java parseLong raises NumberFormatException for values below Long/MIN_VALUE; PTC-Lisp currently returns an arbitrary-precision integer."
      ),
      bug_case(
        "java/long-parse-long-nil-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        "(Long/parseLong nil)",
        "GAP-J01",
        "Java parseLong raises NumberFormatException for nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/long-parse-long-radix-bug-001",
        "java.lang.Long",
        ["Long/parseLong"],
        ~S|(Long/parseLong "10" 16)|,
        "GAP-J15",
        "Java parseLong supports a radix overload; PTC-Lisp currently raises an arity error."
      ),
      bug_case(
        "java/double-parse-double-bug-001",
        "java.lang.Double",
        ["Double/parseDouble"],
        ~S|(Double/parseDouble "x")|,
        "GAP-J01",
        "Java parseDouble raises NumberFormatException, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/double-parse-double-empty-bug-001",
        "java.lang.Double",
        ["Double/parseDouble"],
        ~S|(Double/parseDouble "")|,
        "GAP-J01",
        "Java parseDouble raises NumberFormatException for an empty string, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/double-parse-double-whitespace-bug-001",
        "java.lang.Double",
        ["Double/parseDouble"],
        ~S|(Double/parseDouble " 1.5")|,
        "GAP-J01",
        "Java parseDouble accepts surrounding whitespace, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/double-parse-double-hex-float-bug-001",
        "java.lang.Double",
        ["Double/parseDouble"],
        ~S|(Double/parseDouble "0x1.0p0")|,
        "GAP-J01",
        "Java parseDouble accepts hexadecimal floating-point syntax, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/double-parse-double-nil-bug-001",
        "java.lang.Double",
        ["Double/parseDouble"],
        "(Double/parseDouble nil)",
        "GAP-J01",
        "Java parseDouble raises NullPointerException for nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/float-parse-float-bug-001",
        "java.lang.Float",
        ["Float/parseFloat"],
        ~S|(Float/parseFloat "x")|,
        "GAP-J01",
        "Java parseFloat raises NumberFormatException, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/float-parse-float-empty-bug-001",
        "java.lang.Float",
        ["Float/parseFloat"],
        ~S|(Float/parseFloat "")|,
        "GAP-J01",
        "Java parseFloat raises NumberFormatException for an empty string, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/float-parse-float-whitespace-bug-001",
        "java.lang.Float",
        ["Float/parseFloat"],
        ~S|(Float/parseFloat "1.5 ")|,
        "GAP-J01",
        "Java parseFloat accepts surrounding whitespace, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/float-parse-float-nil-bug-001",
        "java.lang.Float",
        ["Float/parseFloat"],
        "(Float/parseFloat nil)",
        "GAP-J01",
        "Java parseFloat raises NullPointerException for nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        ~S|(Boolean/parseBoolean "x")|,
        "GAP-J02",
        "Java parseBoolean returns false for non-true strings, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-case-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        ~S|(Boolean/parseBoolean "TRUE")|,
        "GAP-J02",
        "Java parseBoolean is case-insensitive for true, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-mixed-case-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        ~S|(Boolean/parseBoolean "TrUe")|,
        "GAP-J02",
        "Java parseBoolean is case-insensitive for mixed-case true, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-empty-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        ~S|(Boolean/parseBoolean "")|,
        "GAP-J02",
        "Java parseBoolean returns false for the empty string, but PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-nil-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        "(Boolean/parseBoolean nil)",
        "GAP-J02",
        "Java parseBoolean returns false for nil; PTC-Lisp currently returns nil."
      ),
      bug_case(
        "java/boolean-parse-boolean-boolean-bug-001",
        "java.lang.Boolean",
        ["Boolean/parseBoolean"],
        "(Boolean/parseBoolean true)",
        "GAP-J02",
        "Java parseBoolean has no boolean overload; PTC-Lisp currently returns nil instead of raising."
      ),
      bug_case(
        "java/util-date-numeric-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. 1000))|,
        "GAP-J03",
        "Java Date numeric constructor uses milliseconds; PTC-Lisp currently treats 1000 as seconds."
      ),
      bug_case(
        "java/util-date-single-millisecond-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. 1))|,
        "GAP-J03",
        "Java Date numeric constructor treats 1 as one millisecond after epoch; PTC-Lisp currently treats it as one second."
      ),
      bug_case(
        "java/util-date-negative-single-millisecond-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. -1))|,
        "GAP-J03",
        "Java Date numeric constructor treats -1 as one millisecond before epoch; PTC-Lisp currently treats it as one second before epoch."
      ),
      bug_case(
        "java/util-date-negative-numeric-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. -1000))|,
        "GAP-J03",
        "Java Date numeric constructor uses milliseconds for negative epochs too; PTC-Lisp currently treats -1000 as seconds."
      ),
      bug_case(
        "java/util-date-is-before-method-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".isBefore"],
        ~S|(.isBefore (java.util.Date. 0) (java.util.Date. 1000))|,
        "GAP-J20",
        "Java Date uses .before, not .isBefore; PTC-Lisp currently exposes a java.time-style alias on Date values."
      ),
      bug_case(
        "java/util-date-is-after-method-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".isAfter"],
        ~S|(.isAfter (java.util.Date. 1000) (java.util.Date. 0))|,
        "GAP-J20",
        "Java Date uses .after, not .isAfter; PTC-Lisp currently exposes a java.time-style alias on Date values."
      ),
      bug_case(
        "java/instant-get-time-bug-001",
        "java.time.Instant",
        [".getTime"],
        ~S|(.getTime (java.time.Instant/parse "1970-01-01T00:00:01Z"))|,
        "GAP-J04",
        "Java Instant has toEpochMilli, not getTime; PTC-Lisp currently exposes getTime on Instant results."
      ),
      bug_case(
        "java/instant-get-time-millis-bug-001",
        "java.time.Instant",
        [".getTime"],
        ~S|(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.123Z"))|,
        "GAP-J04",
        "Java Instant has no getTime method even for fractional-second instants; PTC-Lisp currently exposes millisecond getTime on Instant results."
      ),
      bug_case(
        "java/instant-get-time-offset-bug-001",
        "java.time.Instant",
        [".getTime"],
        ~S|(.getTime (java.time.Instant/parse "1970-01-01T01:00:00+01:00"))|,
        "GAP-J04",
        "Java Instant has no getTime method even for offset-parsed instants; PTC-Lisp currently exposes getTime on Instant results."
      ),
      bug_case(
        "java/instant-get-time-negative-bug-001",
        "java.time.Instant",
        [".getTime"],
        ~S|(.getTime (java.time.Instant/parse "1969-12-31T23:59:59Z"))|,
        "GAP-J04",
        "Java Instant has no getTime method for pre-epoch instants; PTC-Lisp currently exposes getTime on Instant results."
      ),
      bug_case(
        "java/instant-get-time-nanos-bug-001",
        "java.time.Instant",
        [".getTime"],
        ~S|(.getTime (java.time.Instant/parse "1970-01-01T00:00:00.999999999Z"))|,
        "GAP-J04",
        "Java Instant has no getTime method even for nanosecond-precision instants; PTC-Lisp currently exposes millisecond getTime on Instant results."
      ),
      bug_case(
        "java/instant-to-epoch-milli-unsupported-bug-001",
        "java.time.Instant",
        [".toEpochMilli"],
        ~S|(.toEpochMilli (java.time.Instant/parse "1970-01-01T00:00:01Z"))|,
        "GAP-J18",
        "Java Instant exposes toEpochMilli; PTC-Lisp currently rejects the method while exposing getTime instead."
      ),
      bug_case(
        "java/duration-between-date-instant-bug-001",
        "java.time.Duration",
        ["Duration/between"],
        ~S|(.toMillis (java.time.Duration/between (java.util.Date. 0) (java.time.Instant/parse "1970-01-01T00:00:01Z")))|,
        "GAP-J19",
        "Java Duration.between requires Temporal inputs and rejects java.util.Date; PTC-Lisp currently accepts Date values."
      ),
      bug_case(
        "java/duration-between-dates-bug-001",
        "java.time.Duration",
        ["Duration/between"],
        ~S|(.toMillis (java.time.Duration/between (java.util.Date. 0) (java.util.Date. 0)))|,
        "GAP-J19",
        "Java Duration.between requires Temporal inputs and rejects java.util.Date; PTC-Lisp currently accepts Date values."
      ),
      bug_case(
        "java/local-date-plus-days-float-bug-001",
        "java.time.LocalDate",
        [".plusDays"],
        ~S|(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-02") 1.0))|,
        "GAP-J12",
        "Clojure Java interop coerces floating day counts for plusDays; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/local-date-plus-days-fractional-bug-001",
        "java.time.LocalDate",
        [".plusDays"],
        ~S|(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") 1.9))|,
        "GAP-J12",
        "Clojure Java interop coerces fractional day counts for plusDays; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/local-date-plus-days-nan-bug-001",
        "java.time.LocalDate",
        [".plusDays"],
        ~S|(.toEpochDay (.plusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))|,
        "GAP-J12",
        "Clojure Java interop coerces NaN day counts to zero for plusDays; PTC-Lisp currently rejects NaN."
      ),
      bug_case(
        "java/local-date-minus-days-float-bug-001",
        "java.time.LocalDate",
        [".minusDays"],
        ~S|(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-02") 1.0))|,
        "GAP-J12",
        "Clojure Java interop coerces floating day counts for minusDays; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/local-date-minus-days-fractional-bug-001",
        "java.time.LocalDate",
        [".minusDays"],
        ~S|(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") 1.9))|,
        "GAP-J12",
        "Clojure Java interop coerces fractional day counts for minusDays; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/local-date-minus-days-nan-bug-001",
        "java.time.LocalDate",
        [".minusDays"],
        ~S|(.toEpochDay (.minusDays (java.time.LocalDate/parse "2024-01-01") ##NaN))|,
        "GAP-J12",
        "Clojure Java interop coerces NaN day counts to zero for minusDays; PTC-Lisp currently rejects NaN."
      ),
      bug_case(
        "java/string-starts-with-offset-bug-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abc" "b" 1)|,
        "GAP-J05",
        "Java String.startsWith supports a prefix/offset overload; PTC-Lisp currently rejects the arity."
      ),
      bug_case(
        "java/string-starts-with-offset-negative-bug-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abc" "a" -1)|,
        "GAP-J05",
        "Java String.startsWith with a negative offset returns false; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-starts-with-offset-too-large-bug-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abc" "a" 99)|,
        "GAP-J05",
        "Java String.startsWith with an offset beyond the string returns false; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-starts-with-empty-offset-too-large-bug-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abc" "" 4)|,
        "GAP-J05",
        "Java String.startsWith with an empty prefix and offset beyond the string returns false; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-last-index-of-from-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "ababa" "ba" 2)|,
        "GAP-J05",
        "Java String.lastIndexOf supports a substring/from-index overload; PTC-Lisp currently rejects the arity."
      ),
      bug_case(
        "java/string-last-index-of-from-negative-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abcabc" "b" -1)|,
        "GAP-J05",
        "Java String.lastIndexOf with a non-empty substring and negative from-index returns -1; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-last-index-of-from-too-large-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abcabc" "b" 99)|,
        "GAP-J05",
        "Java String.lastIndexOf clamps a non-empty substring from-index above length; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-last-index-of-empty-from-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abc" "" 2)|,
        "GAP-J05",
        "Java String.lastIndexOf handles an empty string with a from-index; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-last-index-of-empty-from-too-large-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abc" "" 4)|,
        "GAP-J05",
        "Java String.lastIndexOf clamps an empty-string from-index above length; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-last-index-of-empty-from-negative-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abc" "" -1)|,
        "GAP-J05",
        "Java String.lastIndexOf with an empty string and negative from-index returns -1; PTC-Lisp currently rejects the overload."
      ),
      bug_case(
        "java/string-index-of-char-code-bug-001",
        "java.lang.String",
        [".indexOf"],
        ~S|(.indexOf "abc" 98)|,
        "GAP-J05",
        "Java String.indexOf supports an integer character-code overload; PTC-Lisp currently requires a string substring."
      ),
      bug_case(
        "java/string-index-of-char-code-from-bug-001",
        "java.lang.String",
        [".indexOf"],
        ~S|(.indexOf "abc" 97 1)|,
        "GAP-J05",
        "Java String.indexOf supports an integer character-code/from-index overload; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "java/string-last-index-of-char-code-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abca" 97)|,
        "GAP-J05",
        "Java String.lastIndexOf supports an integer character-code overload; PTC-Lisp currently requires a string substring."
      ),
      bug_case(
        "java/string-last-index-of-char-code-from-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "abc" 97 1)|,
        "GAP-J05",
        "Java String.lastIndexOf supports an integer character-code/from-index overload; PTC-Lisp currently rejects it."
      ),
      div_case(
        "java/string-starts-with-char-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith "abc" \a)|,
        "DIV-40",
        true,
        "PTC-Lisp has no Character type; \\a is the one-char string \"a\", so .startsWith accepts it as a String prefix (see DIV-35/GAP-S120)."
      ),
      div_case(
        "java/string-ends-with-char-001",
        "java.lang.String",
        [".endsWith"],
        ~S|(.endsWith "abc" \c)|,
        "DIV-40",
        true,
        "PTC-Lisp has no Character type; \\c is the one-char string \"c\", so .endsWith accepts it as a String suffix."
      ),
      div_case(
        "java/string-contains-char-001",
        "java.lang.String",
        [".contains"],
        ~S|(.contains "abc" \b)|,
        "DIV-40",
        true,
        "PTC-Lisp has no Character type; \\b is the one-char string \"b\", so .contains accepts it as a CharSequence."
      ),
      div_case(
        "java/string-length-char-receiver-001",
        "java.lang.String",
        [".length"],
        ~S|(.length \a)|,
        "DIV-41",
        1,
        "PTC-Lisp has no Character type; \\a is the one-char string \"a\", so .length returns 1 instead of raising."
      ),
      div_case(
        "java/string-to-lower-case-char-receiver-001",
        "java.lang.String",
        [".toLowerCase"],
        ~S|(.toLowerCase \A)|,
        "DIV-41",
        "a",
        "PTC-Lisp has no Character type; \\A is the one-char string \"A\", so .toLowerCase returns \"a\" instead of raising."
      ),
      div_case(
        "java/string-to-upper-case-char-receiver-001",
        "java.lang.String",
        [".toUpperCase"],
        ~S|(.toUpperCase \a)|,
        "DIV-41",
        "A",
        "PTC-Lisp has no Character type; \\a is the one-char string \"a\", so .toUpperCase returns \"A\" instead of raising."
      ),
      div_case(
        "java/string-contains-char-receiver-001",
        "java.lang.String",
        [".contains"],
        ~S|(.contains \a "a")|,
        "DIV-41",
        true,
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .contains operates on it as a String."
      ),
      div_case(
        "java/string-index-of-char-receiver-001",
        "java.lang.String",
        [".indexOf"],
        ~S|(.indexOf \a "a")|,
        "DIV-41",
        0,
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .indexOf operates on it as a String."
      ),
      div_case(
        "java/string-last-index-of-char-receiver-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf \a "a")|,
        "DIV-41",
        0,
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .lastIndexOf operates on it as a String."
      ),
      div_case(
        "java/string-starts-with-char-receiver-001",
        "java.lang.String",
        [".startsWith"],
        ~S|(.startsWith \a "a")|,
        "DIV-41",
        true,
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .startsWith operates on it as a String."
      ),
      div_case(
        "java/string-ends-with-char-receiver-001",
        "java.lang.String",
        [".endsWith"],
        ~S|(.endsWith \a "a")|,
        "DIV-41",
        true,
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .endsWith operates on it as a String."
      ),
      div_case(
        "java/string-substring-char-receiver-001",
        "java.lang.String",
        [".substring"],
        ~S|(.substring \a 0)|,
        "DIV-41",
        "a",
        "PTC-Lisp has no Character type; the \\a receiver is the one-char string \"a\", so .substring operates on it as a String."
      ),
      bug_case(
        "java/string-length-utf16-bug-001",
        "java.lang.String",
        [".length"],
        ~S|(.length "😀a")|,
        "GAP-J09",
        "Java String.length returns UTF-16 code units; PTC-Lisp currently returns grapheme count."
      ),
      bug_case(
        "java/string-substring-utf16-bug-001",
        "java.lang.String",
        [".substring"],
        ~S|(.substring "😀a" 0 1)|,
        "GAP-J09",
        "Java String.substring indexes UTF-16 code units; PTC-Lisp currently indexes graphemes."
      ),
      bug_case(
        "java/string-substring-float-start-bug-001",
        "java.lang.String",
        [".substring"],
        ~S|(.substring "abcd" 1.0)|,
        "GAP-J14",
        "Clojure Java interop coerces finite numeric start indexes for String.substring; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/string-substring-float-start-end-bug-001",
        "java.lang.String",
        [".substring"],
        ~S|(.substring "abcd" 1.0 3.0)|,
        "GAP-J14",
        "Clojure Java interop coerces finite numeric start/end indexes for String.substring; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "java/string-index-of-utf16-bug-001",
        "java.lang.String",
        [".indexOf"],
        ~S|(.indexOf "😀a" "a")|,
        "GAP-J09",
        "Java String.indexOf returns UTF-16 code-unit offsets; PTC-Lisp currently returns grapheme offsets."
      ),
      bug_case(
        "java/string-last-index-of-utf16-bug-001",
        "java.lang.String",
        [".lastIndexOf"],
        ~S|(.lastIndexOf "😀a😀" "😀")|,
        "GAP-J09",
        "Java String.lastIndexOf returns UTF-16 code-unit offsets; PTC-Lisp currently returns grapheme offsets."
      ),
      bug_case(
        "java/instant-parse-date-only-bug-001",
        "java.time.Instant",
        ["Instant/parse"],
        ~S|(java.time.Instant/parse "2024-01-02")|,
        "GAP-J06",
        "Java Instant.parse rejects date-only strings; PTC-Lisp currently accepts them as LocalDate values."
      ),
      bug_case(
        "java/instant-parse-no-zone-bug-001",
        "java.time.Instant",
        ["Instant/parse"],
        ~S|(java.time.Instant/parse "2024-01-02T00:00:00")|,
        "GAP-J06",
        "Java Instant.parse rejects date-time strings without an offset or zone; PTC-Lisp currently accepts them as UTC DateTime values."
      ),
      bug_case(
        "java/instant-parse-no-zone-non-midnight-bug-001",
        "java.time.Instant",
        ["Instant/parse"],
        ~S|(java.time.Instant/parse "2024-01-02T03:04:05")|,
        "GAP-J06",
        "Java Instant.parse rejects date-time strings without an offset or zone; PTC-Lisp currently accepts them as UTC DateTime values."
      ),
      bug_case(
        "java/local-date-parse-datetime-bug-001",
        "java.time.LocalDate",
        ["LocalDate/parse"],
        ~S|(java.time.LocalDate/parse "2024-01-02T00:00:00")|,
        "GAP-J06",
        "Java LocalDate.parse rejects date-time strings; PTC-Lisp currently accepts them as DateTime values."
      ),
      bug_case(
        "java/local-date-parse-datetime-non-midnight-bug-001",
        "java.time.LocalDate",
        ["LocalDate/parse"],
        ~S|(java.time.LocalDate/parse "2024-01-02T03:04:05")|,
        "GAP-J06",
        "Java LocalDate.parse rejects date-time strings; PTC-Lisp currently accepts them as DateTime values."
      ),
      bug_case(
        "java/util-date-string-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. "2024-01-02"))|,
        "GAP-J06",
        "Java Date string constructor rejects this ISO date in the oracle; PTC-Lisp currently accepts it."
      ),
      bug_case(
        "java/util-date-legacy-string-constructor-bug-001",
        "java.util.Date",
        ["java.util.Date.", ".getTime"],
        ~S|(.getTime (java.util.Date. "Thu Jan 01 00:00:01 UTC 1970"))|,
        "GAP-J11",
        "Java Date string constructor accepts legacy date strings; PTC-Lisp currently rejects this Java-accepted format."
      ),
      div_case(
        "java/math-min-three-args-001",
        "java.lang.Math",
        ["Math/min"],
        "(Math/min 3 2 1)",
        "DIV-44",
        1,
        "PTC-Lisp min/max are Clojure-variadic; Math/min and Math/max are aliases that stay variadic rather than reproducing Java's two-argument-only overloads."
      ),
      div_case(
        "java/math-min-one-arg-001",
        "java.lang.Math",
        ["Math/min"],
        "(Math/min 1)",
        "DIV-44",
        1,
        "PTC-Lisp min/max are Clojure-variadic; one argument returns that argument rather than raising as Java's two-argument-only overloads would."
      ),
      div_case(
        "java/math-max-three-args-001",
        "java.lang.Math",
        ["Math/max"],
        "(Math/max 1 2 3)",
        "DIV-44",
        3,
        "PTC-Lisp min/max are Clojure-variadic; Math/max stays variadic rather than reproducing Java's two-argument-only overloads."
      ),
      div_case(
        "java/math-max-one-arg-001",
        "java.lang.Math",
        ["Math/max"],
        "(Math/max 1)",
        "DIV-44",
        1,
        "PTC-Lisp min/max are Clojure-variadic; one argument returns that argument rather than raising as Java's two-argument-only overloads would."
      ),
      div_case(
        "java/math-abs-long-min-001",
        "java.lang.Math",
        ["Math/abs"],
        "(Math/abs -9223372036854775808)",
        "DIV-45",
        9_223_372_036_854_775_808,
        "PTC-Lisp uses arbitrary-precision integers, so Math/abs returns the mathematically correct positive value rather than reproducing Java's Long/MIN_VALUE two's-complement overflow."
      ),
      div_case(
        "java/math-abs-bigint-001",
        "java.lang.Math",
        ["Math/abs"],
        "(Math/abs 9223372036854775808)",
        "DIV-45",
        9_223_372_036_854_775_808,
        "PTC-Lisp uses arbitrary-precision integers, so Math/abs accepts values beyond the Java long range rather than failing Java's primitive overload selection."
      ),
      div_case(
        "java/math-max-mixed-numeric-001",
        "java.lang.Math",
        ["Math/max"],
        "(Math/max 1 2.0)",
        "DIV-45",
        2.0,
        "PTC-Lisp min/max compare generically across the numeric tower, so mixed integer/float arguments are accepted rather than failing Java's primitive overload selection."
      ),
      div_case(
        "java/math-min-mixed-numeric-001",
        "java.lang.Math",
        ["Math/min"],
        "(Math/min 1 2.0)",
        "DIV-45",
        1,
        "PTC-Lisp min/max compare generically across the numeric tower, so mixed integer/float arguments are accepted rather than failing Java's primitive overload selection."
      ),
      div_case(
        "java/math-min-nil-001",
        "java.lang.Math",
        ["Math/min"],
        "(Math/min nil 1)",
        "DIV-45",
        1,
        "PTC-Lisp min/max use total ordering, so nil sorts as the smallest value rather than raising as Java's primitive overloads would."
      ),
      div_case(
        "java/math-max-string-001",
        "java.lang.Math",
        ["Math/max"],
        ~S|(Math/max "a" 1)|,
        "DIV-45",
        "a",
        "PTC-Lisp min/max use total ordering across types, so a string compares against a number rather than raising as Java's primitive overloads would."
      ),
      div_case(
        "java/math-round-negative-half-001",
        "java.lang.Math",
        ["Math/round"],
        "(Math/round -1.5)",
        "DIV-43",
        -2,
        "PTC-Lisp round uses round-half-away-from-zero, so -1.5 rounds to -2 rather than Java's floor(x + 0.5) result of -1."
      ),
      div_case(
        "java/math-round-nan-001",
        "java.lang.Math",
        ["Math/round", "str"],
        "(str (Math/round ##NaN))",
        "DIV-43",
        "NaN",
        "PTC-Lisp round preserves the NaN signal value rather than reproducing Java's NaN -> 0 long conversion."
      ),
      div_case(
        "java/math-round-pos-inf-001",
        "java.lang.Math",
        ["Math/round", "str"],
        "(str (Math/round ##Inf))",
        "DIV-43",
        "Infinity",
        "PTC-Lisp round preserves the infinity signal value rather than reproducing Java's saturation to Long/MAX_VALUE."
      ),
      div_case(
        "java/math-round-neg-inf-001",
        "java.lang.Math",
        ["Math/round", "str"],
        "(str (Math/round ##-Inf))",
        "DIV-43",
        "-Infinity",
        "PTC-Lisp round preserves the negative-infinity signal value rather than reproducing Java's saturation to Long/MIN_VALUE."
      ),
      div_case(
        "java/math-round-integer-overload-001",
        "java.lang.Math",
        ["Math/round"],
        "(Math/round 1)",
        "DIV-45",
        1,
        "PTC-Lisp round accepts integers (returning them unchanged) rather than failing Java's float/double-only overload selection."
      ),
      div_case(
        "java/math-round-bigint-overload-001",
        "java.lang.Math",
        ["Math/round"],
        "(Math/round 9223372036854775808)",
        "DIV-45",
        9_223_372_036_854_775_808,
        "PTC-Lisp round accepts arbitrary-precision integers (returning them unchanged) rather than failing Java's float/double-only overload selection."
      ),
      regression_case(
        "java/math-pow-negative-fractional-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow -1 0.5)",
        ["GAP-J13"],
        [:numeric]
      ),
      regression_case(
        "java/math-pow-zero-negative-exponent-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow 0 -1)",
        ["GAP-J13"],
        [:numeric]
      ),
      regression_case(
        "java/math-pow-one-nan-exponent-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow 1 ##NaN)",
        ["GAP-J13"],
        [:numeric]
      ),
      regression_case(
        "java/math-pow-one-infinite-exponent-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow 1 ##Inf)",
        ["GAP-J13"],
        [:numeric]
      ),
      regression_case(
        "java/math-pow-negative-one-infinite-exponent-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow -1 ##Inf)",
        ["GAP-J13"],
        [:numeric]
      ),
      regression_case(
        "java/math-pow-negative-zero-negative-odd-exponent-001",
        "java.lang.Math",
        ["Math/pow"],
        "(Math/pow -0.0 -3)",
        ["GAP-J13"],
        [:numeric]
      ),
      div_case(
        "java/math-ceil-double-rendering-001",
        "java.lang.Math",
        ["Math/ceil", "str"],
        "(str (Math/ceil 1.2))",
        "DIV-42",
        "2",
        "PTC-Lisp ceil/floor are integer-returning extensions, so the result renders as 2 rather than reproducing Java's double 2.0 shape."
      ),
      div_case(
        "java/math-floor-double-rendering-001",
        "java.lang.Math",
        ["Math/floor", "str"],
        "(str (Math/floor -1.2))",
        "DIV-42",
        "-2",
        "PTC-Lisp ceil/floor are integer-returning extensions, so the result renders as -2 rather than reproducing Java's double -2.0 shape."
      )
    ]
  end

  defp divergence_cases do
    [
      div_case(
        "div/parse-long-001",
        "clojure.core",
        ["parse-long"],
        ~S|(parse-long "abc")|,
        "DIV-18",
        nil,
        "Bad external parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-long-nil-001",
        "clojure.core",
        ["parse-long"],
        "(parse-long nil)",
        "DIV-18",
        nil,
        "Nil parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-double-001",
        "clojure.core",
        ["parse-double"],
        ~S|(parse-double :x)|,
        "DIV-18",
        nil,
        "Non-string parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-double-nil-001",
        "clojure.core",
        ["parse-double"],
        "(parse-double nil)",
        "DIV-18",
        nil,
        "Nil parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-boolean-001",
        "clojure.core",
        ["parse-boolean"],
        ~S|(parse-boolean :x)|,
        "DIV-18",
        nil,
        "Non-string parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-boolean-boolean-001",
        "clojure.core",
        ["parse-boolean"],
        "(parse-boolean true)",
        "DIV-18",
        nil,
        "Boolean parse input returns nil instead of raising."
      ),
      div_case(
        "div/parse-boolean-nil-001",
        "clojure.core",
        ["parse-boolean"],
        "(parse-boolean nil)",
        "DIV-18",
        nil,
        "Nil parse input returns nil instead of raising."
      ),
      div_case(
        "div/symbol-predicate-001",
        "clojure.core",
        ["symbol?"],
        "(symbol? 'x)",
        "DIV-19",
        false,
        "Quoted symbols are not supported as runtime values."
      ),
      div_case(
        "div/name-symbol-001",
        "clojure.core",
        ["name"],
        "(name 'x)",
        "DIV-19",
        {:error, :runtime_error},
        "Quoted symbols are not supported as runtime values, so name only applies to PTC-supported identifier values."
      ),
      div_case(
        "div/loop-limit-001",
        "clojure.core",
        ["loop", "recur"],
        "(loop [i 0] (if (< i 1001) (recur (inc i)) i))",
        "DIV-01",
        {:error, :loop_limit_exceeded},
        "Loop/recur execution is bounded for sandbox safety."
      ),
      unsupported_case(
        "div/lazy-range-unsupported-001",
        "clojure.core",
        ["range"],
        "(take 3 (range))",
        "DIV-02: unbounded lazy sequences are outside PTC-Lisp.",
        ["DIV-02"]
      ),
      div_case(
        "div/eval-unsupported-001",
        "clojure.core",
        ["eval"],
        "(eval (list + 1 2))",
        "DIV-04",
        {:error, :unbound_var},
        "Macros/eval/metaprogramming are outside the sandbox."
      ),
      unsupported_case(
        "div/mutable-atom-unsupported-001",
        "clojure.core",
        ["atom"],
        "(deref (atom 1))",
        "DIV-05: mutable reference types are outside PTC-Lisp.",
        ["DIV-05"]
      ),
      div_case(
        "div/duplicate-computed-set-key-001",
        "clojure.core",
        ["set"],
        ~S|(let [a 1 b 1] #{a b})|,
        "DIV-06",
        MapSet.new([1]),
        "Computed duplicate set values deduplicate instead of raising."
      ),
      div_case(
        "div/ns-unsupported-001",
        "clojure.core",
        ["ns"],
        "(ns my.ns)",
        "DIV-07",
        {:error, :unbound_var},
        "User-defined namespaces are outside PTC-Lisp."
      ),
      div_case(
        "div/full-java-class-unsupported-001",
        "java",
        ["java.lang.String"],
        "java.lang.String",
        "DIV-08",
        {:error, :unbound_var},
        "Arbitrary host class access is outside PTC-Lisp."
      ),
      unsupported_case(
        "div/file-io-unsupported-001",
        "clojure.core",
        ["slurp"],
        ~S|(slurp "/tmp/ptc-runner-conformance-no-file")|,
        "DIV-09: file I/O is outside PTC-Lisp.",
        ["DIV-09"]
      ),
      div_case(
        "div/try-catch-unsupported-001",
        "clojure.core",
        ["try", "catch"],
        "(try (/ 1 0) (catch Exception e :bad))",
        "DIV-10",
        {:error, :unbound_var},
        "Exception handling is outside PTC-Lisp; use fail for explicit program errors."
      ),
      div_case(
        "div/defmulti-unsupported-001",
        "clojure.core",
        ["defmulti"],
        "(defmulti area :shape)",
        "DIV-11",
        {:error, :unbound_var},
        "Multimethods and protocols are outside PTC-Lisp."
      ),
      div_case(
        "div/transduce-unsupported-001",
        "clojure.core",
        ["transduce"],
        "(transduce (map inc) + [1 2])",
        "DIV-12",
        {:error, :unbound_var},
        "Transducers are outside PTC-Lisp."
      ),
      div_case(
        "div/namespaced-keyword-001",
        "clojure.core",
        ["keyword"],
        ":foo/bar",
        "DIV-13",
        {:error, :unbound_var},
        "Namespaced keywords are not part of the PTC-Lisp data model."
      ),
      div_case(
        "div/namespaced-keyword-function-001",
        "clojure.core",
        ["keyword"],
        ~S|(keyword "foo/bar")|,
        "DIV-13",
        {:error, :runtime_error},
        "Namespaced keywords are not part of the PTC-Lisp data model, including keyword coercion."
      ),
      div_case(
        "div/namespaced-keyword-map-destructuring-001",
        "clojure.core",
        ["let"],
        ~S|(let [{:keys [a/b]} {:a/b 1}] b)|,
        "DIV-13",
        {:error, :parse_error},
        "Namespaced keywords are not part of the PTC-Lisp data model, including map destructuring keys."
      ),
      div_case(
        "div/empty-keyword-function-001",
        "clojure.core",
        ["keyword"],
        ~S|(keyword "")|,
        "DIV-34",
        {:error, :runtime_error},
        "PTC-Lisp keywords require at least one keyword character."
      ),
      div_case(
        "div/strict-keyword-character-function-001",
        "clojure.core",
        ["keyword"],
        ~S|(keyword ".")|,
        "DIV-35",
        {:error, :runtime_error},
        "PTC-Lisp keywords use a stricter character set than Clojure keywords."
      ),
      div_case(
        "div/if-let-destructuring-001",
        "clojure.core",
        ["if-let"],
        "(if-let [{:keys [a]} {:a 1}] a nil)",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/if-let-vector-destructuring-001",
        "clojure.core",
        ["if-let"],
        "(if-let [[a b] [1 2]] [a b] nil)",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/when-let-destructuring-001",
        "clojure.core",
        ["when-let"],
        "(when-let [[a b] [1 2]] [a b])",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/when-let-map-destructuring-001",
        "clojure.core",
        ["when-let"],
        "(when-let [{:keys [a]} {:a 1}] a)",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/if-some-destructuring-001",
        "clojure.core",
        ["if-some"],
        "(if-some [[a b] [1 2]] [a b] nil)",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/if-some-map-destructuring-001",
        "clojure.core",
        ["if-some"],
        "(if-some [{:keys [a]} {:a nil}] a :none)",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/when-some-destructuring-001",
        "clojure.core",
        ["when-some"],
        "(when-some [[a b] [1 2]] [a b])",
        "DIV-14",
        {:error, :invalid_form},
        "Conditional binding forms only support simple symbol bindings; use let for destructuring."
      ),
      div_case(
        "div/multi-arity-defn-001",
        "clojure.core",
        ["defn"],
        "(defn f ([x] x) ([x y] (+ x y)))",
        "DIV-15",
        {:error, :invalid_form},
        "Multi-arity defn is outside PTC-Lisp."
      ),
      div_case(
        "div/multi-arity-fn-001",
        "clojure.core",
        ["fn"],
        "((fn ([x] x) ([x y] (+ x y))) 1 2)",
        "DIV-15",
        {:error, :invalid_form},
        "Multi-arity fn is outside PTC-Lisp; use rest args or separate functions."
      ),
      div_case(
        "div/defn-precondition-ignored-001",
        "clojure.core",
        ["defn"],
        "(do (defn f [x] {:pre [(pos? x)]} x) (f -1))",
        "DIV-16",
        -1,
        "Pre/post condition maps are not enforced in PTC-Lisp."
      ),
      unsupported_case(
        "div/decimal-predicate-001",
        "clojure.core",
        ["decimal?"],
        "(decimal? 1.0M)",
        "DIV-20: BigDecimal literals are outside the PTC numeric model, so this cannot reach decimal?."
      ),
      unsupported_case(
        "div/ratio-predicate-001",
        "clojure.core",
        ["ratio?"],
        "(ratio? 1/2)",
        "DIV-20: Ratio literals are outside the PTC numeric model, so this cannot reach ratio?."
      ),
      div_case(
        "div/format-nil-001",
        "clojure.core",
        ["format"],
        ~S|(format "x%s" nil)|,
        "DIV-21",
        "x",
        "Nil renders as an empty string in PTC format."
      ),
      div_case(
        "div/subs-oob-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abc" 9)|,
        "DIV-22",
        "",
        "Out-of-range data input returns an empty-string signal value."
      ),
      div_case(
        "div/subs-start-end-oob-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abc" 4 4)|,
        "DIV-22",
        "",
        "Out-of-range start and end indexes return an empty-string signal value instead of raising."
      ),
      div_case(
        "div/subs-negative-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abc" -1)|,
        "DIV-22",
        "",
        "Negative starts return an empty-string signal value instead of raising."
      ),
      div_case(
        "div/subs-end-oob-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abc" 1 99)|,
        "DIV-22",
        "bc",
        "Out-of-range end indexes are clamped as a recoverable substring signal instead of raising."
      ),
      div_case(
        "div/subs-reversed-range-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abc" 2 1)|,
        "DIV-22",
        "",
        "Reversed substring ranges return an empty-string signal value instead of raising."
      ),
      div_case(
        "div/string-grapheme-count-001",
        "clojure.core",
        ["count"],
        ~S|(count "😀a")|,
        "DIV-36",
        2,
        "PTC-Lisp string sequence operations use Unicode graphemes instead of JVM UTF-16 code units."
      ),
      div_case(
        "div/string-grapheme-nth-001",
        "clojure.core",
        ["nth"],
        ~S|(nth "😀a" 0)|,
        "DIV-36",
        "😀",
        "PTC-Lisp string sequence operations use Unicode graphemes instead of JVM UTF-16 code units."
      ),
      div_case(
        "div/string-grapheme-index-of-001",
        "clojure.string",
        ["index-of"],
        ~S|(clojure.string/index-of "😀a" "a")|,
        "DIV-36",
        1,
        "PTC-Lisp string index helpers return grapheme offsets instead of JVM UTF-16 code-unit offsets."
      ),
      div_case(
        "div/string-grapheme-last-index-of-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "😀a😀" "😀")|,
        "DIV-36",
        2,
        "PTC-Lisp string index helpers return grapheme offsets instead of JVM UTF-16 code-unit offsets."
      ),
      div_case(
        "div/string-grapheme-subs-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "😀a" 1)|,
        "DIV-36",
        "a",
        "PTC-Lisp string substring indexes use Unicode graphemes instead of JVM UTF-16 code units."
      ),
      div_case(
        "div/string-grapheme-split-with-001",
        "clojure.core",
        ["split-with"],
        ~S|(split-with #(not= % "c") "abcd")|,
        "DIV-36",
        [["a", "b"], ["c", "d"]],
        "PTC-Lisp string sequence operations expose one-character strings, so predicates compare against string values instead of JVM Character values."
      ),
      bug_case(
        "core/subs-float-index-bug-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abcd" 1.0 2.0)|,
        "GAP-S79",
        "Clojure subs accepts numeric index arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/subs-float-start-bug-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abcd" 1.0)|,
        "GAP-S79",
        "Clojure subs accepts a floating start index by coercing to int; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/subs-float-end-bug-001",
        "clojure.core",
        ["subs"],
        ~S|(subs "abcd" 1 3.0)|,
        "GAP-S79",
        "Clojure subs accepts a floating end index by coercing to int; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/nth-float-index-bug-001",
        "clojure.core",
        ["nth"],
        "(nth [10 20] 1.0)",
        "GAP-S79",
        "Clojure nth accepts numeric index arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/subvec-float-start-bug-001",
        "clojure.core",
        ["subvec"],
        "(subvec [1 2 3] 1.0)",
        "GAP-S79",
        "Clojure subvec accepts a floating start index by coercing to int; PTC-Lisp currently rejects it."
      ),
      bug_case(
        "core/subvec-float-start-end-bug-001",
        "clojure.core",
        ["subvec"],
        "(subvec [1 2 3] 1.0 2.0)",
        "GAP-S79",
        "Clojure subvec accepts floating start/end indexes by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/subvec-float-truncating-indexes-bug-001",
        "clojure.core",
        ["subvec"],
        "(subvec [1 2 3] 0.9 2.9)",
        "GAP-S79",
        "Clojure subvec truncates finite floating start/end indexes; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/take-float-count-bug-001",
        "clojure.core",
        ["take"],
        "(take 1.0 [10 20])",
        "GAP-S79",
        "Clojure take accepts numeric count arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/drop-float-count-bug-001",
        "clojure.core",
        ["drop"],
        "(drop 1.0 [10 20])",
        "GAP-S79",
        "Clojure drop accepts numeric count arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/split-at-float-count-bug-001",
        "clojure.core",
        ["split-at"],
        "(split-at 1.0 [1 2])",
        "GAP-S79",
        "Clojure split-at accepts numeric count arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/partition-float-count-bug-001",
        "clojure.core",
        ["partition"],
        "(partition 2.0 [1 2 3])",
        "GAP-S79",
        "Clojure partition accepts floating size arguments; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/partition-float-step-bug-001",
        "clojure.core",
        ["partition"],
        "(partition 2 1.0 [1 2 3])",
        "GAP-S79",
        "Clojure partition accepts floating step arguments by coercing them through drop; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/partition-float-step-pad-bug-001",
        "clojure.core",
        ["partition"],
        "(partition 2 1.0 [:x] [1 2 3])",
        "GAP-S79",
        "Clojure partition accepts floating step arguments in the padded overload; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/partition-all-float-count-bug-001",
        "clojure.core",
        ["partition-all"],
        "(partition-all 2.0 [1 2 3])",
        "GAP-S79",
        "Clojure partition-all accepts floating size arguments by coercing them to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/partition-all-float-step-bug-001",
        "clojure.core",
        ["partition-all"],
        "(partition-all 2 1.0 [1 2 3])",
        "GAP-S79",
        "Clojure partition-all accepts floating step arguments by coercing them to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/nthrest-float-count-bug-001",
        "clojure.core",
        ["nthrest"],
        "(nthrest [1 2 3] 1.0)",
        "GAP-S79",
        "Clojure nthrest accepts numeric count arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "core/nthnext-float-count-bug-001",
        "clojure.core",
        ["nthnext"],
        "(nthnext [1 2 3] 1.0)",
        "GAP-S79",
        "Clojure nthnext accepts numeric count arguments such as doubles by coercing to int; PTC-Lisp currently rejects them."
      ),
      bug_case(
        "string/last-index-of-negative-from-bug-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "abc" "a" -1)|,
        "GAP-S80",
        "Clojure string/last-index-of returns nil for a negative from-index; PTC-Lisp currently returns 0."
      ),
      bug_case(
        "string/last-index-of-empty-negative-from-bug-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "abc" "" -1)|,
        "GAP-S80",
        "Clojure string/last-index-of returns nil for an empty search string with negative from-index; PTC-Lisp currently returns 0."
      ),
      bug_case(
        "string/index-of-float-truncating-from-index-bug-001",
        "clojure.string",
        ["index-of"],
        ~S|(clojure.string/index-of "abcabc" "b" 1.9)|,
        "GAP-S124",
        "Clojure string/index-of truncates finite numeric from-index arguments; PTC-Lisp currently rejects floats."
      ),
      bug_case(
        "string/last-index-of-float-truncating-from-index-bug-001",
        "clojure.string",
        ["last-index-of"],
        ~S|(clojure.string/last-index-of "ababa" "a" 3.9)|,
        "GAP-S124",
        "Clojure string/last-index-of truncates finite numeric from-index arguments; PTC-Lisp currently rejects floats."
      ),
      div_case(
        "div/subvec-oob-001",
        "clojure.core",
        ["subvec"],
        "(subvec [1 2 3] 0 9)",
        "DIV-26",
        [1, 2, 3],
        "Out-of-range end index clamps instead of raising."
      ),
      div_case(
        "div/subvec-negative-start-001",
        "clojure.core",
        ["subvec"],
        "(subvec [1 2 3] -1)",
        "DIV-26",
        [1, 2, 3],
        "Negative start index clamps instead of raising."
      ),
      div_case(
        "div/pop-empty-001",
        "clojure.core",
        ["pop"],
        "(pop [])",
        "DIV-26",
        nil,
        "Empty pop returns nil instead of raising."
      ),
      div_case(
        "div/contains-vector-membership-001",
        "clojure.core",
        ["contains?"],
        "(contains? [1 2] 2)",
        "DIV-27",
        true,
        "PTC-Lisp contains? uses collection membership semantics for vectors/lists."
      ),
      div_case(
        "div/contains-vector-index-present-value-absent-001",
        "clojure.core",
        ["contains?"],
        "(contains? [10 20] 1)",
        "DIV-27",
        false,
        "PTC-Lisp contains? checks vector/list membership, not vector index presence."
      ),
      div_case(
        "div/contains-map-entry-index-present-001",
        "clojure.core",
        ["contains?"],
        "(contains? (first (seq {:a 1})) 0)",
        "DIV-27",
        false,
        "PTC-Lisp contains? checks map-entry membership, not map-entry index presence."
      ),
      div_case(
        "div/contains-map-entry-key-member-001",
        "clojure.core",
        ["contains?"],
        "(contains? (first (seq {:a 1})) :a)",
        "DIV-27",
        true,
        "PTC-Lisp contains? treats map-entry keys as members instead of using Clojure index semantics."
      ),
      div_case(
        "div/json-parse-invalid-001",
        "ptc.extension",
        ["json/parse-string"],
        ~S|(json/parse-string "not json")|,
        "DIV-23",
        nil,
        "Invalid JSON returns nil instead of raising."
      ),
      div_case(
        "div/json-generate-keyword-001",
        "ptc.extension",
        ["json/generate-string"],
        "(json/generate-string :fs)",
        "DIV-24",
        nil,
        "Non-encodable JSON values return nil instead of lossy stringification."
      ),
      div_case(
        "div/type-keyword-001",
        "clojure.core",
        ["type"],
        "(type 1)",
        "DIV-28",
        :number,
        "PTC-Lisp type returns stable PTC type keywords instead of host JVM classes."
      ),
      div_case(
        "div/first-map-direct-001",
        "clojure.core",
        ["first"],
        "(first {:a 1})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/rest-map-direct-001",
        "clojure.core",
        ["rest"],
        "(rest {:a 1 :b 2})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/second-map-direct-001",
        "clojure.core",
        ["second"],
        "(second {:a 1 :b 2})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/last-map-direct-001",
        "clojure.core",
        ["last"],
        "(last {:a 1})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/next-map-direct-001",
        "clojure.core",
        ["next"],
        "(next {:a 1})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/reverse-map-direct-001",
        "clojure.core",
        ["reverse"],
        "(reverse {:a 1 :b 2})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/interpose-map-direct-001",
        "clojure.core",
        ["interpose"],
        "(interpose :x {:a 1 :b 2})",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/interleave-map-direct-001",
        "clojure.core",
        ["interleave"],
        "(interleave {:a 1} [:x])",
        "DIV-29",
        {:error, :type_error},
        "Direct positional map access raises; use seq/entries/keys/vals for ordered map views."
      ),
      div_case(
        "div/lt-mixed-scalar-001",
        "clojure.core",
        ["<"],
        ~S|(< "a" 1)|,
        "DIV-30",
        false,
        "Ordering predicates use PTC's recoverable total term ordering instead of raising."
      ),
      div_case(
        "div/lt-string-scalar-001",
        "clojure.core",
        ["<"],
        ~S|(< "a" "b")|,
        "DIV-30",
        true,
        "Ordering predicates use PTC's recoverable total term ordering for nonnumeric scalar values."
      ),
      div_case(
        "div/lte-char-scalar-001",
        "clojure.core",
        ["<="],
        ~S|(<= \a \a)|,
        "DIV-30",
        true,
        "Ordering predicates use PTC's recoverable total term ordering for character values."
      ),
      div_case(
        "div/gt-string-scalar-001",
        "clojure.core",
        [">"],
        ~S|(> "b" "a")|,
        "DIV-30",
        true,
        "Ordering predicates use PTC's recoverable total term ordering for nonnumeric scalar values."
      ),
      div_case(
        "div/gte-char-scalar-001",
        "clojure.core",
        [">="],
        ~S|(>= \b \a)|,
        "DIV-30",
        true,
        "Ordering predicates use PTC's recoverable total term ordering for character values."
      ),
      div_case(
        "div/sort-mixed-scalar-001",
        "clojure.core",
        ["sort"],
        ~S|(sort [1 "a"])|,
        "DIV-30",
        [1, "a"],
        "sort uses PTC's recoverable total term ordering for mixed scalar data."
      ),
      div_case(
        "div/sort-nil-001",
        "clojure.core",
        ["sort"],
        "(sort [1 nil])",
        "DIV-30",
        [1, nil],
        "nil sorts according to PTC's total term ordering, not Clojure's nil-first compare."
      ),
      div_case(
        "div/sort-by-nil-key-001",
        "clojure.core",
        ["sort-by"],
        "(sort-by :a [{:a nil} {:a 1}])",
        "DIV-30",
        [%{"a" => 1}, %{"a" => nil}],
        "sort-by uses PTC's total term ordering for transformed nil values."
      ),
      div_case(
        "div/compare-nil-001",
        "clojure.core",
        ["compare"],
        "(compare nil 1)",
        "DIV-30",
        1,
        "compare uses PTC's total term ordering for nil and mixed values."
      ),
      div_case(
        "div/compare-map-001",
        "clojure.core",
        ["compare"],
        "(compare {:a 1} {:a 2})",
        "DIV-30",
        -1,
        "compare uses PTC's total term ordering for maps instead of Clojure's Comparable-only behavior."
      ),
      div_case(
        "div/compare-string-keyword-001",
        "clojure.core",
        ["compare"],
        ~S|(compare "a" :a)|,
        "DIV-30",
        1,
        "compare uses PTC's total term ordering for mixed scalar values instead of Clojure's Comparable-only behavior."
      ),
      div_case(
        "div/compare-string-number-001",
        "clojure.core",
        ["compare"],
        ~S|(compare "a" 1)|,
        "DIV-30",
        1,
        "compare uses PTC's total term ordering for mixed scalar values instead of Clojure's Comparable-only behavior."
      ),
      div_case(
        "div/max-nil-001",
        "clojure.core",
        ["max"],
        "(max nil 1)",
        "DIV-30",
        nil,
        "max uses PTC's total term ordering for nil instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/min-nil-001",
        "clojure.core",
        ["min"],
        "(min nil 1)",
        "DIV-30",
        1,
        "min uses PTC's total term ordering for nil instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/max-string-number-001",
        "clojure.core",
        ["max"],
        ~S|(max "a" 1)|,
        "DIV-30",
        "a",
        "max uses PTC's total term ordering for mixed scalar values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/min-string-number-001",
        "clojure.core",
        ["min"],
        ~S|(min "a" 1)|,
        "DIV-30",
        1,
        "min uses PTC's total term ordering for mixed scalar values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/min-boolean-001",
        "clojure.core",
        ["min"],
        "(min true false)",
        "DIV-30",
        false,
        "min uses PTC's total term ordering for nonnumeric values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/max-keyword-001",
        "clojure.core",
        ["max"],
        "(max :a :b)",
        "DIV-30",
        "b",
        "max uses PTC's total term ordering for nonnumeric values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/min-key-boolean-001",
        "clojure.core",
        ["min-key"],
        "(min-key identity true false)",
        "DIV-30",
        false,
        "min-key uses PTC's total term ordering for transformed nonnumeric values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/max-key-keyword-001",
        "clojure.core",
        ["max-key"],
        "(max-key identity :a :b)",
        "DIV-30",
        "b",
        "max-key uses PTC's total term ordering for transformed nonnumeric values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/max-key-nil-key-001",
        "clojure.core",
        ["max-key"],
        "(max-key :a {:a nil} {:a 1})",
        "DIV-30",
        %{"a" => nil},
        "max-key uses PTC's total term ordering for transformed nil values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/min-key-nil-key-001",
        "clojure.core",
        ["min-key"],
        "(min-key :a {:a nil} {:a 1})",
        "DIV-30",
        %{"a" => 1},
        "min-key uses PTC's total term ordering for transformed nil values instead of Clojure's numeric-only behavior."
      ),
      div_case(
        "div/zero-predicate-nil-001",
        "clojure.core",
        ["zero?"],
        "(zero? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/pos-predicate-nil-001",
        "clojure.core",
        ["pos?"],
        "(pos? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/even-predicate-nil-001",
        "clojure.core",
        ["even?"],
        "(even? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/odd-predicate-nil-001",
        "clojure.core",
        ["odd?"],
        "(odd? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/even-predicate-char-001",
        "clojure.core",
        ["even?"],
        ~S|(even? \a)|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/odd-predicate-char-001",
        "clojure.core",
        ["odd?"],
        ~S|(odd? \a)|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/neg-predicate-string-001",
        "clojure.core",
        ["neg?"],
        ~S|(neg? "x")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/zero-predicate-numeric-string-001",
        "clojure.core",
        ["zero?"],
        ~S|(zero? "0")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/pos-predicate-numeric-string-001",
        "clojure.core",
        ["pos?"],
        ~S|(pos? "1")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/neg-predicate-numeric-string-001",
        "clojure.core",
        ["neg?"],
        ~S|(neg? "-1")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/infinite-predicate-nil-001",
        "clojure.core",
        ["infinite?"],
        "(infinite? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/nan-predicate-nil-001",
        "clojure.core",
        ["NaN?"],
        "(NaN? nil)",
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/infinite-predicate-string-001",
        "clojure.core",
        ["infinite?"],
        ~S|(infinite? "x")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/nan-predicate-string-001",
        "clojure.core",
        ["NaN?"],
        ~S|(NaN? "x")|,
        "DIV-31",
        false,
        "Numeric predicates return false for nil/non-numeric inputs instead of raising."
      ),
      div_case(
        "div/equality-int-float-001",
        "clojure.core",
        ["="],
        "(= 1 1.0)",
        "DIV-32",
        true,
        "PTC-Lisp equality is numeric type-independent; use == in Clojure for that behavior."
      ),
      div_case(
        "div/not-equality-int-float-001",
        "clojure.core",
        ["not="],
        "(not= 1 1.0)",
        "DIV-32",
        false,
        "PTC-Lisp not= follows type-independent numeric equality."
      ),
      div_case(
        "div/case-numeric-equality-001",
        "clojure.core",
        ["case"],
        "(case 1.0 1 :one :other)",
        "DIV-32",
        "one",
        "PTC-Lisp case dispatch follows its type-independent numeric equality policy."
      ),
      div_case(
        "div/compare-nan-001",
        "clojure.core",
        ["compare"],
        "(compare ##NaN 1)",
        "DIV-33",
        {:error, :type_error},
        "PTC-Lisp treats NaN as unordered for compare instead of returning an arbitrary ordering."
      ),
      div_case(
        "div/compare-nan-self-001",
        "clojure.core",
        ["compare"],
        "(compare ##NaN ##NaN)",
        "DIV-33",
        {:error, :type_error},
        "PTC-Lisp treats NaN as unordered even for self-comparison."
      ),
      div_case(
        "div/seq-map-sorted-001",
        "clojure.core",
        ["seq"],
        "(seq {:b 2 :a 1})",
        "DIV-38",
        [["a", 1], ["b", 2]],
        "PTC-Lisp map sequence views are sorted by key instead of preserving Clojure map iteration order."
      ),
      div_case(
        "div/keys-map-sorted-001",
        "clojure.core",
        ["keys"],
        "(keys {:b 2 :a 1})",
        "DIV-38",
        ["a", "b"],
        "PTC-Lisp map key views are sorted by key instead of preserving Clojure map iteration order."
      ),
      div_case(
        "div/vals-map-sorted-001",
        "clojure.core",
        ["vals"],
        "(vals {:b 2 :a 1})",
        "DIV-38",
        [1, 2],
        "PTC-Lisp map value views follow sorted key order instead of preserving Clojure map iteration order."
      ),
      div_case(
        "div/pr-str-map-rendering-001",
        "clojure.core",
        ["pr-str"],
        "(pr-str {:b 2 :a 1})",
        "DIV-39",
        "{:a 1 :b 2}",
        "PTC-Lisp readable map rendering is deterministic, key-sorted, and space-separated."
      ),
      div_case(
        "div/pr-str-nested-map-rendering-001",
        "clojure.core",
        ["pr-str"],
        "(pr-str {:a {:b 2 :c 3}})",
        "DIV-39",
        "{:a {:b 2 :c 3}}",
        "PTC-Lisp readable map rendering omits optional commas recursively."
      ),
      div_case(
        "div/format-map-rendering-001",
        "clojure.core",
        ["format"],
        ~S|(format "%s" {:b 2 :a 1})|,
        "DIV-39",
        "{:a 1 :b 2}",
        "PTC-Lisp format %s uses the same deterministic collection rendering as str/pr-str."
      ),
      div_case(
        "div/quot-long-min-overflow-001",
        "clojure.core",
        ["quot"],
        "(quot -9223372036854775808 -1)",
        "DIV-37",
        9_223_372_036_854_775_808,
        "PTC-Lisp integers are arbitrary-precision, so quot does not preserve the JVM Long/MIN_VALUE overflow edge."
      ),
      div_case(
        "div/abs-long-min-overflow-001",
        "clojure.core",
        ["abs"],
        "(abs -9223372036854775808)",
        "DIV-37",
        9_223_372_036_854_775_808,
        "PTC-Lisp integers are arbitrary-precision, so abs does not preserve the JVM Long/MIN_VALUE overflow edge."
      ),
      div_case(
        "div/int-predicate-bigint-001",
        "clojure.core",
        ["int?"],
        "(int? 922337203685477580812345)",
        "DIV-37",
        true,
        "PTC-Lisp integers are arbitrary-precision, so int? has no distinct JVM fixed-width integer boundary."
      ),
      div_case(
        "div/pos-int-predicate-bigint-001",
        "clojure.core",
        ["pos-int?"],
        "(pos-int? 922337203685477580812345)",
        "DIV-37",
        true,
        "PTC-Lisp integers are arbitrary-precision, so pos-int? has no distinct JVM fixed-width integer boundary."
      ),
      div_case(
        "div/neg-int-predicate-bigint-001",
        "clojure.core",
        ["neg-int?"],
        "(neg-int? -922337203685477580812345)",
        "DIV-37",
        true,
        "PTC-Lisp integers are arbitrary-precision, so neg-int? has no distinct JVM fixed-width integer boundary."
      ),
      div_case(
        "div/nat-int-predicate-bigint-001",
        "clojure.core",
        ["nat-int?"],
        "(nat-int? 922337203685477580812345)",
        "DIV-37",
        true,
        "PTC-Lisp integers are arbitrary-precision, so nat-int? has no distinct JVM fixed-width integer boundary."
      ),
      div_case(
        "div/conj-list-001",
        "clojure.core",
        ["conj", "list"],
        "(conj (list 2 3) 1)",
        "DIV-25",
        [2, 3, 1],
        "PTC-Lisp list is a vector alias, so conj appends."
      ),
      div_case(
        "div/conj-nil-multiple-001",
        "clojure.core",
        ["conj"],
        "(conj nil :a :b)",
        "DIV-25",
        ["a", "b"],
        "PTC-Lisp has no list type, so conj on nil builds a vector in append order."
      ),
      div_case(
        "div/pop-list-001",
        "clojure.core",
        ["pop", "list"],
        "(pop (list 1 2 3))",
        "DIV-25",
        [1, 2],
        "PTC-Lisp list is a vector alias, so pop removes the last element."
      ),
      div_case(
        "div/peek-list-001",
        "clojure.core",
        ["peek", "list"],
        "(peek (list 1 2))",
        "DIV-25",
        2,
        "PTC-Lisp list is a vector alias, so peek returns the last element."
      ),
      div_case(
        "div/vector-predicate-list-001",
        "clojure.core",
        ["vector?", "list"],
        "(vector? (list 1))",
        "DIV-25",
        true,
        "PTC-Lisp list is a vector alias, so vector? returns true."
      ),
      div_case(
        "div/list-predicate-list-001",
        "clojure.core",
        ["list?"],
        "(list? (list 1))",
        "DIV-25",
        {:error, :unbound_var},
        "PTC-Lisp has no list runtime type, so list? is intentionally not provided."
      ),
      div_case(
        "div/list-predicate-vector-001",
        "clojure.core",
        ["list?"],
        "(list? [1 2])",
        "DIV-25",
        {:error, :unbound_var},
        "PTC-Lisp has no list runtime type, so list? is intentionally not provided."
      ),
      unsupported_case(
        "unsupported/lazy-range-001",
        "clojure.core",
        ["range"],
        "(take 3 (range))",
        "DIV-02: unbounded lazy sequences are outside PTC-Lisp."
      ),
      unsupported_case(
        "unsupported/atom-001",
        "clojure.core",
        ["atom"],
        "(deref (atom 1))",
        "DIV-05: mutable reference types are outside PTC-Lisp."
      )
    ]
  end

  defp ptc_cases do
    [
      %{
        id: "ptc/sum-by-001",
        namespace: "ptc.extension",
        vars: ["sum-by"],
        form: ~S|(sum-by :n [{:n 1} {:n 2}])|,
        policy: :ptc_extension,
        ptc_expected: 3,
        tags: [:ptc_extension, :collection]
      },
      %{
        id: "ptc/json-parse-001",
        namespace: "ptc.extension",
        vars: ["json/parse-string"],
        form: ~S|(json/parse-string "{\"a\":1}")|,
        policy: :ptc_extension,
        ptc_expected: %{"a" => 1},
        tags: [:ptc_extension]
      }
    ]
  end

  defp c(id, namespace, vars, form, tags) do
    %{
      id: id,
      namespace: namespace,
      vars: vars,
      form: form,
      policy: :match,
      source: "manual",
      tags: tags
    }
  end

  defp regression_case(id, namespace, vars, form, regression_ids, tags) do
    id
    |> c(namespace, vars, form, tags)
    |> Map.put(:regression_ids, regression_ids)
  end

  defp div_case(id, namespace, vars, form, div_id, ptc_expected, reason) do
    %{
      id: id,
      namespace: namespace,
      vars: vars,
      form: form,
      policy: {:diverges, div_id},
      source: "manual",
      reason: reason,
      ptc_expected: ptc_expected,
      tags: [:edge, :error_semantics]
    }
  end

  defp bug_case(id, namespace, vars, form, gap_id, reason) do
    %{
      id: id,
      namespace: namespace,
      vars: vars,
      form: form,
      policy: {:bug, gap_id},
      source: "manual",
      reason: reason,
      tags: [:edge]
    }
  end

  defp unsupported_case(id, namespace, vars, form, reason, regression_ids \\ []) do
    %{
      id: id,
      namespace: namespace,
      vars: vars,
      form: form,
      policy: :unsupported,
      source: "manual",
      reason: reason,
      regression_ids: regression_ids,
      tags: [:edge]
    }
  end
end
