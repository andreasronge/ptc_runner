import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import {
  access,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  writeFile,
} from "node:fs/promises";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { expected, startFixture } from "./fixture.mjs";

const execute = promisify(execFile);
const directory = dirname(fileURLToPath(import.meta.url));
const live = process.argv[2] === "--live";
const envFile = live ? process.argv[3] : null;
assert.ok(
  !live || envFile,
  "Usage: node run.mjs [--live /absolute/path/to/.env]",
);

const output = await mkdtemp(join(directory, ".ptc-private-demo-"));
const parserStore = join(output, "parsers");
const fixture = await startFixture();

async function save(path, value) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

async function commandPath(name) {
  const names =
    process.platform === "win32"
      ? [`${name}.cmd`, `${name}.exe`, name]
      : [name];
  for (const candidateDirectory of (process.env.PATH ?? "").split(delimiter)) {
    for (const candidate of names.map((file) =>
      join(candidateDirectory, file),
    )) {
      try {
        await access(candidate);
        return candidate;
      } catch {}
    }
  }
  throw new Error(`${name} is not available on PATH`);
}

async function ptc(args) {
  try {
    return await execute(process.env.PTC ?? "ptc", args, {
      cwd: directory,
      env: { ...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin },
      timeout: 210000,
      maxBuffer: 4 * 1024 * 1024,
    });
  } catch (error) {
    throw new Error(error.stderr || error.message);
  }
}

async function run(name, host, input, envFilePath = null) {
  const inputPath = join(output, `${name}-input.json`);
  const resultPath = join(output, `${name}-result.json`);
  const envelopePath = join(output, `${name}-envelope.json`);
  await save(inputPath, input);
  await ptc([
    "run",
    "ptc-project.json",
    "--host-config",
    host,
    "--input",
    inputPath,
    "--output",
    resultPath,
    "--envelope",
    envelopePath,
    ...(envFilePath ? ["--env-file", resolve(envFilePath)] : []),
  ]);
  const envelope = JSON.parse(await readFile(envelopePath, "utf8"));
  assert.equal(envelope.status, "ok");
  return { result: JSON.parse(await readFile(resultPath, "utf8")), envelope };
}

let failed;
try {
  await mkdir(parserStore, { mode: 0o700 });
  const hostSource = live ? "ptc-host.live.json" : "ptc-host.json";
  const host = JSON.parse(await readFile(join(directory, hostSource), "utf8"));
  const packageInstall = join(output, "mcp-packages");
  const packages = [];
  if (!process.env.PTC_WEB_CLI) packages.push("ptc-web@0.1.0");
  if (!process.env.PTC_FS_MCP_CLI) packages.push("ptc-fs-mcp@0.4.0");
  if (packages.length > 0) {
    await execute(
      await commandPath("npm"),
      [
        "install",
        "--prefix",
        packageInstall,
        "--no-save",
        "--no-audit",
        "--no-fund",
        "--package-lock=false",
        ...packages,
      ],
      {
        cwd: directory,
        env: process.env,
        timeout: 120000,
        maxBuffer: 4 * 1024 * 1024,
      },
    );
  }

  const webCli = process.env.PTC_WEB_CLI
    ? resolve(process.env.PTC_WEB_CLI)
    : join(packageInstall, "node_modules/ptc-web/dist/src/cli.js");
  host.install.web.transport.command = process.execPath;
  host.install.web.transport.args = [webCli];

  const fsCli = process.env.PTC_FS_MCP_CLI
    ? resolve(process.env.PTC_FS_MCP_CLI)
    : join(packageInstall, "node_modules/ptc-fs-mcp/dist/cli.js");
  host.install["candidate-store"].transport.command = process.execPath;
  host.install["candidate-store"].transport.args = [
    fsCli,
    "--root",
    parserStore,
    "--include",
    "*.clj",
    "--max-write-bytes",
    "65536",
  ];

  const runtimeHost = join(output, "ptc-host.json");
  await save(runtimeHost, host);
  if (!live)
    await copyFile(
      join(directory, "replay.jsonl"),
      join(output, "replay.jsonl"),
    );

  const input = {
    url: `${fixture.origin}/quotes`,
    held_out_url: `${fixture.origin}/held-out`,
  };
  const repaired = await run("01-repair", runtimeHost, input, envFile);
  assert.equal(repaired.result.status, "passed");
  assert.equal(repaired.result.mode, "repaired");
  assert.deepEqual(repaired.result.records, expected["/quotes"]);
  assert.deepEqual(repaired.result.checks, { original: 2, held_out: 2 });
  assert.ok(
    repaired.envelope.execution.usage.llm_usage.length > 0,
    "repair must use the model",
  );

  const candidate = await readFile(join(parserStore, "candidate.clj"), "utf8");
  const accepted = await readFile(join(parserStore, "accepted.clj"), "utf8");
  assert.equal(
    accepted,
    candidate,
    "only the verified candidate should become accepted",
  );

  const reused = await run("02-reuse", runtimeHost, input, envFile);
  assert.equal(reused.result.status, "passed");
  assert.equal(reused.result.mode, "reused");
  assert.deepEqual(reused.result.records, expected["/quotes"]);
  assert.equal(
    reused.envelope.execution.usage.llm_usage.length,
    0,
    "reuse must not call a model",
  );

  const report = {
    status: "passed",
    mode: live ? "live" : "replay",
    first_run: repaired.result,
    second_run: reused.result,
    candidate: join(parserStore, "candidate.clj"),
    accepted: join(parserStore, "accepted.clj"),
    artifacts: output,
  };
  await save(join(output, "report.json"), report);
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  failed = error;
  console.error(error.message);
  process.exitCode = 1;
} finally {
  await fixture.close();
}
