// Reporting helpers stay separate from the live lab driver so accounting can
// be regression-tested without installing ptc-web or calling a model.

const measuredInteger = (value) =>
  Number.isSafeInteger(value) && value >= 0 ? value : null;

export function usageOf(envelope) {
  const usage = envelope?.execution?.usage ?? {};
  const calls = usage.capability_calls ?? {};
  const byTool = {};
  let model = 0;
  for (const [key, count] of Object.entries(calls)) {
    if (key.endsWith("/llm-request")) model += count;
    else byTool[key.replace(/^mission\//, "")] = count;
  }

  const spend = usage.llm_spend;
  let inputTokens = null;
  let outputTokens = null;
  let microUsd = null;
  if (spend?.state === "empty") {
    inputTokens = 0;
    outputTokens = 0;
    microUsd = 0;
  } else if (spend?.state === "unpriced") {
    const input = measuredInteger(spend.input);
    const output = measuredInteger(spend.output);
    if (input !== null && output !== null) {
      inputTokens = input;
      outputTokens = output;
    }
  } else if (spend?.state === "available") {
    const input = measuredInteger(spend.input);
    const output = measuredInteger(spend.output);
    const cost = measuredInteger(spend.total_cost?.microunits);
    if (input !== null && output !== null && cost !== null) {
      inputTokens = input;
      outputTokens = output;
      microUsd = cost;
    }
  }

  return {
    by_tool: byTool,
    page_tool_calls: Object.values(byTool).reduce((a, b) => a + b, 0),
    model_requests: model,
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    micro_usd: microUsd,
    spend_state: spend?.state ?? "unknown",
    refusals: Object.values(usage.capability_refusals ?? {}).reduce(
      (a, b) => a + b,
      0,
    ),
  };
}

export function aggregate(rows, key) {
  let subtotal = 0;
  let known = 0;
  let unaccounted = 0;

  for (const row of rows) {
    if (row[key] === null || row[key] === undefined) {
      unaccounted += 1;
    } else {
      subtotal += row[key];
      known += 1;
    }
  }

  return { subtotal: known === 0 ? null : subtotal, unaccounted };
}

export function formatAggregate({ subtotal, unaccounted }) {
  if (unaccounted === 0) return String(subtotal ?? 0);
  if (subtotal === null) return `n/a (${unaccounted} unaccounted)`;
  return `${subtotal} subtotal (${unaccounted} unaccounted)`;
}

export function formatSpend(row) {
  const value = (amount) => (amount === null ? "n/a" : String(amount));

  return `${value(row.input_tokens)} in / ${value(row.output_tokens)} out / ${value(row.micro_usd)} microUSD`;
}
