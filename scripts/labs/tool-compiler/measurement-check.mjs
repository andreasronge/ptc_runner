import assert from "node:assert/strict";
import { taskWithUrl, totalIfKnown, usageOf } from "./measurement.mjs";

const url = "http://127.0.0.1:43210/quotes";
assert.match(taskWithUrl("Extract the records.", url), new RegExp(url));

const measured = (llm_spend) => usageOf({ execution: { usage: { llm_spend } } });
assert.deepEqual(
  measured({
    state: "available",
    input: 12,
    output: 3,
    total_cost: { microunits: 7 },
  }),
  {
    by_tool: {},
    page_tool_calls: 0,
    model_requests: 0,
    input_tokens: 12,
    output_tokens: 3,
    micro_usd: 7,
    spend_state: "available",
    refusals: 0,
  },
);
assert.equal(measured({ state: "unpriced", input: 12, output: 3 }).micro_usd, null);
assert.equal(measured({ state: "incomplete" }).input_tokens, null);
assert.equal(measured({ state: "overflow" }).output_tokens, null);
assert.equal(measured(undefined).micro_usd, null);
assert.equal(totalIfKnown([{ micro_usd: 2 }, { micro_usd: 3 }], "micro_usd"), 5);
assert.equal(totalIfKnown([{ micro_usd: 2 }, { micro_usd: null }], "micro_usd"), null);

process.stdout.write("tool-compiler task and measurement boundaries passed\n");
