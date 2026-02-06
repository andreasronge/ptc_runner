# Planning Examples

## Example: Stock Research Mission

**Mission:** "Research Apple stock price and summarize key findings"

**Available Tools:**
- `search`: Search the web for information
- `fetch_price`: Get current stock price for a symbol

**Ideal Plan:**
```json
{
  "tasks": [
    {
      "id": "fetch_apple_price",
      "agent": "data_fetcher",
      "input": "Fetch the current stock price for AAPL",
      "signature": "{price :float, currency :string}",
      "verification": "(if (number? (get data/result \"price\")) true \"Price must be a number\")",
      "on_verification_failure": "retry"
    },
    {
      "id": "search_apple_news",
      "agent": "researcher",
      "input": "Search for recent Apple stock news and analyst opinions",
      "signature": "{articles [{title :string, source :string}]}",
      "verification": "(> (count (get data/result \"articles\")) 0)",
      "on_verification_failure": "retry"
    },
    {
      "id": "synthesize_findings",
      "agent": "summarizer",
      "type": "synthesis_gate",
      "signature": "{symbol :string, price :float, trend :string, key_headlines [:string]}",
      "input": "Consolidate price data and news into a JSON summary with fields: symbol, price, trend, key_headlines",
      "depends_on": ["fetch_apple_price", "search_apple_news"]
    }
  ],
  "agents": {
    "data_fetcher": {
      "prompt": "You fetch financial data accurately. Return structured JSON with price, currency, and change fields.",
      "tools": ["fetch_price"]
    },
    "researcher": {
      "prompt": "You search for relevant information and return structured results. Return JSON with an articles array.",
      "tools": ["search"]
    },
    "summarizer": {
      "prompt": "You consolidate data from multiple sources into clean, structured JSON. Be concise and factual.",
      "tools": []
    }
  }
}
```

**Why This Plan Works:**
- **Descriptive IDs**: `fetch_apple_price` not `task1`
- **Focused tasks**: Each task does one thing well
- **Type-safe verification**: Checks data types and presence
- **Clear synthesis input**: Specifies exact output fields
- **Appropriate failure handling**: `retry` for recoverable failures

## Example: Computation Between Fetch and Synthesis

When a mission requires derived values (ratios, comparisons, aggregations), create a
dedicated computation agent between the data-fetching and synthesis steps.

**Mission:** "Which region had the fastest revenue growth last year?"

**Available Tools:**
- `fetch_section`: Retrieve a document section by ID

**Ideal Plan:**
```json
{
  "tasks": [
    {
      "id": "fetch_current_year",
      "agent": "fetcher",
      "input": "Fetch the section with current year regional revenue breakdown",
      "signature": "{node_id :string, content :string}",
      "on_verification_failure": "retry"
    },
    {
      "id": "fetch_prior_year",
      "agent": "fetcher",
      "input": "Fetch the section with prior year regional revenue breakdown",
      "signature": "{node_id :string, content :string}",
      "on_verification_failure": "retry"
    },
    {
      "id": "compute_growth",
      "agent": "calculator",
      "input": "Extract current and prior year revenue for each region, then compute year-over-year growth rate as ((current - prior) / prior) * 100 for each region",
      "depends_on": ["fetch_current_year", "fetch_prior_year"],
      "output": "ptc_lisp",
      "signature": "{regions [{name :string, current :float, prior :float, growth_pct :float}]}",
      "verification": "(> (count (get data/result \"regions\")) 0)",
      "on_verification_failure": "retry"
    },
    {
      "id": "final_answer",
      "agent": "synthesizer",
      "type": "synthesis_gate",
      "input": "Identify which region grew fastest, by how much, and what might explain the difference",
      "depends_on": ["compute_growth"],
      "signature": "{fastest_region :string, growth_pct :float, summary :string}"
    }
  ],
  "agents": {
    "fetcher": {
      "prompt": "Retrieve the requested document section. Return its content with metadata.",
      "tools": ["fetch_section"]
    },
    "calculator": {
      "prompt": "You are a quantitative analyst. Extract numeric values into let bindings and use arithmetic expressions (/, *, +, -) to compute results. Do NOT calculate values mentally — write the expressions and let the interpreter compute them. Example: (let [current 450.0 prior 380.0] {\"growth_pct\" (* 100.0 (/ (- current prior) prior))})",
      "tools": []
    },
    "synthesizer": {
      "prompt": "Synthesize the computed results into a clear, evidence-based answer.",
      "tools": []
    }
  }
}
```

**Why This Plan Works:**
- **Decomposition first**: Works backwards from the question to identify what specific values and formulas are needed
- **Targeted fetches**: Only fetches sections containing the required input values
- **Explicit computation step**: The `calculator` agent extracts numbers and computes derived values — not buried in synthesis
- **`output: "ptc_lisp"`**: The computation task uses PTC-Lisp mode so the interpreter verifies arithmetic instead of the LLM computing values mentally
- **Typed signatures**: Each step has a precise schema so downstream tasks know what they receive
