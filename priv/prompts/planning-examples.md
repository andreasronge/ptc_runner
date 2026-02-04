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
      "verification": "(if (number? (get data/result \"price\")) true \"Price must be a number\")",
      "on_verification_failure": "retry"
    },
    {
      "id": "search_apple_news",
      "agent": "researcher",
      "input": "Search for recent Apple stock news and analyst opinions",
      "verification": "(> (count (get data/result \"articles\")) 0)",
      "on_verification_failure": "retry"
    },
    {
      "id": "synthesize_findings",
      "agent": "summarizer",
      "type": "synthesis_gate",
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
