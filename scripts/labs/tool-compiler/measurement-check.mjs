import assert from "node:assert/strict";
import { taskWithUrl } from "./measurement.mjs";

const url = "http://127.0.0.1:43210/quotes";
assert.match(taskWithUrl("Extract the records.", url), new RegExp(url));

process.stdout.write("tool-compiler task boundary passed\n");
