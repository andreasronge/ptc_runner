// Arm A of the tool-compiler experiment: a model orchestrates the raw page
// tools itself. Records what that costs, so a compiled domain tool has a
// baseline to beat.
//
//   node run.mjs [--env-file /absolute/path/to/.env]
//
// Needs Node 20+, npm, Playwright Chromium (ptc-web installs it), `ptc` on
// PATH, and an OPENROUTER_API_KEY in the environment or the env file.
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expected, startFixture } from "./fixture.mjs";
import { recordsAreCorrect } from "./driver.mjs";

const execute = promisify(execFile);
const directory = dirname(fileURLToPath(import.meta.url));
const envFlag = process.argv.indexOf("--env-file");
const envFile = envFlag === -1 ? null : resolve(process.argv[envFlag + 1]);

const TASK =
  "Return every quotation on the page as records with `text` and `author`. " +
  "The page structure is not known in advance, so inspect it before you extract. " +
  "Ignore navigation and boilerplate. Answer with {\"records\": [{\"text\": ..., \"author\": ...}]}.";

async function commandPath(name) {
  for (const candidate of (process.env.PATH ?? "").split(delimiter)) {
    try {
      await readdir(candidate);
      const entries = await readdir(candidate);
      if (entries.includes(name)) return join(candidate, name);
    } catch {}
  }
  throw new Error(`${name} is not available on PATH`);
}

// The envelope already counts every capability call and every token, so the
// trace is kept for the Arm B authoring agent rather than for arithmetic.
function usageOf(envelope) {
  const usage = envelope?.execution?.usage ?? {};
  const calls = usage.capability_calls ?? {};
  const byTool = {};
  let model = 0;
  for (const [key, count] of Object.entries(calls)) {
    if (key.endsWith("/llm-request")) model += count;
    else byTool[key.replace(/^mission\//, "")] = count;
  }
  const spend = usage.llm_spend ?? {};
  // A run closed by a limit reports `incomplete`, and its token counts are not
  // accounted. Reporting zero there would understate the arm.
  const accounted = spend.state !== "incomplete";
  return {
    by_tool: byTool,
    page_tool_calls: Object.values(byTool).reduce((a, b) => a + b, 0),
    model_requests: model,
    input_tokens: accounted ? (spend.input ?? 0) : null,
    output_tokens: accounted ? (spend.output ?? 0) : null,
    micro_usd: accounted ? (spend.total_cost?.microunits ?? 0) : null,
    spend_state: spend.state ?? "unknown",
    refusals: Object.values(usage.capability_refusals ?? {}).reduce(
      (a, b) => a + b,
      0,
    ),
  };
}

const output = await mkdtemp(join(directory, ".arm-a-"));
const fixture = await startFixture();
let failure;

try {
  const packages = join(output, "packages");
  await execute(
    await commandPath("npm"),
    [
      "install",
      "--prefix",
      packages,
      "--no-save",
      "--no-audit",
      "--no-fund",
      "--package-lock=false",
      "ptc-web@0.1.0",
    ],
    { cwd: directory, env: process.env, timeout: 300000, maxBuffer: 8 << 20 },
  );

  const host = JSON.parse(
    await readFile(join(directory, "ptc-host.json"), "utf8"),
  );
  host.install.web.transport.command = process.execPath;
  host.install.web.transport.args = [
    join(packages, "node_modules/ptc-web/dist/src/cli.js"),
  ];
  const hostPath = join(output, "ptc-host.json");
  await writeFile(hostPath, JSON.stringify(host, null, 2), { mode: 0o600 });

  const arms = (process.env.ARMS ?? "passthrough,compiled").split(",");
  const results = [];
  for (const arm of arms)
  for (const path of Object.keys(expected)) {
    const name = `${arm}-${path.slice(1)}`;
    const inputPath = join(output, `${name}-input.json`);
    const resultPath = join(output, `${name}-result.json`);
    const envelopePath = join(output, `${name}-envelope.json`);
    const inspectPath = join(output, `${name}.ptcins`);
    const traceDir = join(output, `${name}-traces`);
    await mkdir(traceDir, { mode: 0o700 });
    await writeFile(
      inputPath,
      JSON.stringify({ task: TASK, url: `${fixture.origin}${path}` }),
      { mode: 0o600 },
    );

    const started = Date.now();
    let status = "ok";
    try {
      await execute(
        process.env.PTC ?? "ptc",
        [
          "run",
          `${arm}/ptc.json`,
          "--host-config",
          hostPath,
          "--input",
          inputPath,
          "--output",
          resultPath,
          "--envelope",
          envelopePath,
          "--trace-dir",
          traceDir,
          "--inspect",
          inspectPath,
          ...(envFile ? ["--env-file", envFile] : []),
        ],
        {
          cwd: directory,
          env: { ...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin },
          timeout: 600000,
          maxBuffer: 8 << 20,
        },
      );
    } catch (error) {
      status = "failed";
      process.stderr.write(`${name}: ${error.stderr || error.message}\n`);
    }

    const envelope = await readFile(envelopePath, "utf8")
      .then(JSON.parse)
      .catch(() => ({}));
    const value = await readFile(resultPath, "utf8")
      .then(JSON.parse)
      .catch(() => null);

    const measured = usageOf(envelope);
    results.push({
      arm,
      page: path,
      status: status === "failed" ? status : (envelope.status ?? status),
      failure: envelope?.result?.error?.code ?? envelope?.error?.code ?? null,
      seconds: Math.round((Date.now() - started) / 100) / 10,
      trace_dir: traceDir,
      inspection: inspectPath,
      ...measured,
      records: Array.isArray(value?.records) ? value.records.length : null,
      correct: recordsAreCorrect(expected[path], value?.records),
    });
  }

  await writeFile(
    join(directory, "results.json"),
    `${JSON.stringify(results, null, 2)}\n`,
    { mode: 0o600 },
  );

  const titles = {
    passthrough: "Arm A: the model orchestrates the raw page tools",
    compiled: "Arm B: one compiled tool, no model in the loop",
  };
  for (const arm of arms) {
  process.stdout.write(`\n${titles[arm] ?? arm}\n\n`);
  process.stdout.write(
    "page        status  calls  model  in_tokens  out_tokens  micro_usd  refus  records  correct\n",
  );
  for (const row of results.filter((r) => r.arm === arm)) {
    process.stdout.write(
      [
        row.page.padEnd(11),
        String(row.status).padEnd(7),
        String(row.page_tool_calls).padStart(5),
        String(row.model_requests).padStart(7),
        String(row.input_tokens ?? "n/a").padStart(11),
        String(row.output_tokens ?? "n/a").padStart(12),
        String(row.micro_usd ?? "n/a").padStart(11),
        String(row.refusals).padStart(7),
        String(row.records ?? "-").padStart(9),
        String(row.correct).padStart(9),
      ].join("") + "\n",
    );
  }
  }
  const total = (arm, key) =>
    results
      .filter((r) => r.arm === arm)
      .reduce((sum, r) => sum + (r[key] ?? 0), 0);
  const right = (arm) =>
    results.filter((r) => r.arm === arm && r.correct).length;
  process.stdout.write("\ntotals\n\n");
  process.stdout.write("arm          calls  model  in_tokens  micro_usd  correct\n");
  for (const arm of arms) {
    process.stdout.write(
      [
        arm.padEnd(13),
        String(total(arm, "page_tool_calls")).padStart(5),
        String(total(arm, "model_requests")).padStart(7),
        String(total(arm, "input_tokens")).padStart(11),
        String(total(arm, "micro_usd")).padStart(11),
        `${right(arm)}/${results.filter((r) => r.arm === arm).length}`.padStart(9),
      ].join("") + "\n",
    );
  }
  process.stdout.write(`written: ${join(directory, "results.json")}\n`);
  if (results.some((row) => row.status !== "ok" || !row.correct)) {
    process.exitCode = 1;
  }
} catch (error) {
  failure = error;
} finally {
  await fixture.close();
}

if (failure) {
  process.stderr.write(`${failure.stack ?? failure}\n`);
  process.exitCode = 1;
}
