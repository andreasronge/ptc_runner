export function taskWithUrl(task, url) {
  return `${task} Open this URL: ${url}`;
}

export function usageOf(envelope) {
  const usage = envelope?.execution?.usage ?? {};
  const calls = usage.capability_calls ?? {};
  const byTool = {};
  let model = 0;
  for (const [key, count] of Object.entries(calls)) {
    if (key.endsWith("/llm-request")) model += count;
    else byTool[key.replace(/^mission\//, "")] = count;
  }

  const spend = usage.llm_spend ?? {};
  let inputTokens = null;
  let outputTokens = null;
  let microUsd = null;
  switch (spend.state) {
    case "available":
      inputTokens = spend.input;
      outputTokens = spend.output;
      microUsd = spend.total_cost?.microunits;
      break;
    case "unpriced":
      inputTokens = spend.input;
      outputTokens = spend.output;
      break;
    case "empty":
      inputTokens = 0;
      outputTokens = 0;
      break;
    case "incomplete":
    case "overflow":
      break;
    default:
      break;
  }

  return {
    by_tool: byTool,
    page_tool_calls: Object.values(byTool).reduce((a, b) => a + b, 0),
    model_requests: model,
    input_tokens: Number.isFinite(inputTokens) ? inputTokens : null,
    output_tokens: Number.isFinite(outputTokens) ? outputTokens : null,
    micro_usd: Number.isFinite(microUsd) ? microUsd : null,
    spend_state: spend.state ?? "unknown",
    refusals: Object.values(usage.capability_refusals ?? {}).reduce(
      (a, b) => a + b,
      0,
    ),
  };
}

export function totalIfKnown(rows, key) {
  const values = rows.map((row) => row[key]);
  return values.every(Number.isFinite)
    ? values.reduce((sum, value) => sum + value, 0)
    : null;
}
