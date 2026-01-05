# PTC-Lisp Memory Addon

Multi-turn execution for complex tasks requiring observation and judgment.

<!-- PTC_PROMPT_START -->

### Multi-Turn Execution (ReAct pattern)

You solve tasks by iterating in steps. Each step you produce:

```
Thought: (brief reasoning about what to do next)
Action:
```clojure
(your program here)
```
```

The system executes your program and shows you the Observation (result).
Then you produce the next Thought/Action based on what you observed.

**Rules:**
- Do not assume results - wait for the Observation
- If the next step depends on runtime values, do another step
- When done, use `(return value)` to produce the final answer

### Turn 2+ Access Rules

- You SEE previous result as feedback
- **NEVER copy/paste result data into your code** - this doesn't work!
- Your code can ONLY access: `ctx/*` (original data), stored values (as plain symbols), and `*1`/`*2`/`*3` (recent results)

**Turn history:** `*1` is the previous turn's result, `*2` is two turns ago, `*3` is three turns ago. Returns `nil` if turn doesn't exist. Results are truncated (~1KB), so store important values in memory.

After observing a result:
1. Analyze what you observed and draw a conclusion
2. Hardcode your CONCLUSION (e.g., a name or value), not the raw data
3. Write code using `ctx/*` to compute based on your conclusion

**Wrong** (embedding result data):
```clojure
(let [data [{:x "a" :val 50000} ...]]  ; NO - can't embed results!
  ...)
```

**Right** (hardcoding conclusion):
```clojure
(return 50000)  ; Just return the value you observed
; OR filter ctx/* using your concluded key
```

### Memory Storage Rules

**Only maps are stored in memory.** When your program returns a map, its keys become accessible as plain symbols in subsequent turns.

- **Map result** `{:foo 1 :bar 2}` → stored as `foo` and `bar` symbols
- **List/scalar result** `[...]` or `42` → NOT stored, only shown as feedback

If you need to access a list in a later turn, wrap it in a map:
```clojure
{:results (->> ctx/data (filter ...))}  ; → `results` available next turn
```

### Memory Accumulation

**Important:** When you return a map, its keys **overwrite** any previous values with the same keys.

To accumulate results across multiple tool calls (e.g., pagination):

**Wrong** (results get overwritten each turn):
```clojure
; Turn 1: (call "search" {:query "topic"})
;   → results = [doc1, doc2], cursor = "5"
; Turn 2: (call "search" {:query "topic" :cursor cursor})
;   → results = [doc3] ← OVERWRITES Turn 1 results!
; Turn 3: (return results) → only [doc3], lost doc1 and doc2!
```

**Right** (save results before next call overwrites):
```clojure
; Turn 1: Call search
(call "search" {:query "topic"})

; Turn 2: Save current results, then fetch more
{:all-results results
 :next (call "search" {:query "topic" :cursor cursor})}

; Turn 3: Combine and return
(return (concat all-results results))
```

### Example

Query: "Which employee's expense claims look suspicious? Return their employee_id."

**Step 1:**
```
Thought: I need to explore expense patterns per employee to see what's there.
Action:
```clojure
(->> ctx/expenses
     (group-by :employee_id)
     (map (fn [[id claims]]
       {:id id :count (count claims) :total (sum-by :amount claims)
        :categories (distinct (pluck :category claims))})))
```
```

**Observation:**
```
[{:id 101 :count 45 :total 4500 :categories ["travel" "meals" "office"]}
 {:id 102 :count 3 :total 15000 :categories ["equipment"]}
 {:id 103 :count 120 :total 3600 :categories ["meals"]}]
```

**Step 2:**
```
Thought: Looking at the data, 102 has only 3 claims but $15k total, all in one category.
That pattern (few high-value claims, single category) looks most suspicious.
Action:
```clojure
(return 102)
```
```

<!-- PTC_PROMPT_END -->
