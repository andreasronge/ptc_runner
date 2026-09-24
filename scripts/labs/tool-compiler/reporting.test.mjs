import assert from "node:assert/strict";
import test from "node:test";
import { aggregate, formatAggregate, usageOf } from "./reporting.mjs";

function envelope(llmSpend) {
  return { execution: { usage: { llm_spend: llmSpend } } };
}

test("mixed known and incomplete spend is labelled as a subtotal", () => {
  const rows = [
    usageOf(
      envelope({
        state: "available",
        input: 100,
        output: 20,
        total_cost: { microunits: 5527 },
      }),
    ),
    usageOf(envelope({ state: "incomplete" })),
  ];

  assert.deepEqual(aggregate(rows, "micro_usd"), {
    subtotal: 5527,
    unaccounted: 1,
  });
  assert.equal(
    formatAggregate(aggregate(rows, "micro_usd")),
    "5527 subtotal (1 unaccounted)",
  );
});

test("all unknown spend stays unavailable", () => {
  const rows = [
    usageOf(envelope({ state: "incomplete" })),
    usageOf({}),
    usageOf(envelope({ state: "available", input: 10, output: 2 })),
  ];

  assert.deepEqual(aggregate(rows, "input_tokens"), {
    subtotal: null,
    unaccounted: 3,
  });
  assert.equal(
    formatAggregate(aggregate(rows, "input_tokens")),
    "n/a (3 unaccounted)",
  );
});

test("an empty spend envelope reports authoritative zero usage", () => {
  const row = usageOf(envelope({ state: "empty" }));

  assert.equal(row.input_tokens, 0);
  assert.equal(row.output_tokens, 0);
  assert.equal(row.micro_usd, 0);
  assert.equal(formatAggregate(aggregate([row], "micro_usd")), "0");
});
