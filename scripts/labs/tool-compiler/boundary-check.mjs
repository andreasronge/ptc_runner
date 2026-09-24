// Credential-free boundary check for the pinned ptc-web extraction surface.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { startFixture } from "./fixture.mjs";

const execute = promisify(execFile);
const directory = dirname(fileURLToPath(import.meta.url));
const repository = resolve(directory, "../../..");
const output = await mkdtemp(join(directory, ".boundary-"));
const fixture = await startFixture();

try {
  const packages = join(output, "packages");
  await execute("npm", [
    "install", "--prefix", packages, "--no-save", "--no-audit", "--no-fund",
    "--package-lock=false", "ptc-web@0.1.0",
  ], { cwd: directory, timeout: 300_000, maxBuffer: 8 << 20 });

  const browsers = join(output, "browsers");
  await execute(process.execPath, [
    join(packages, "node_modules/playwright/cli.js"), "install", "chromium",
  ], {
    cwd: directory,
    env: { ...process.env, PLAYWRIGHT_BROWSERS_PATH: browsers },
    timeout: 300_000,
    maxBuffer: 8 << 20,
  });

  const host = JSON.parse(await readFile(join(directory, "ptc-host.json"), "utf8"));
  delete host.credentials.model_key;
  delete host.install.model;
  host.credentials.playwright_browsers = { literal: browsers };
  host.install.web.transport.command = process.execPath;
  host.install.web.transport.args = [join(packages, "node_modules/ptc-web/dist/src/cli.js")];
  host.install.web.transport.env.PLAYWRIGHT_BROWSERS_PATH = {
    binding: "playwright_browsers",
  };

  const hostPath = join(output, "ptc-host.json");
  const inputPath = join(output, "input.json");
  const resultPath = join(output, "result.json");
  const inspectPath = join(output, "inspection.ptcins");
  const tracePath = join(output, "traces");
  await mkdir(tracePath);
  await writeFile(hostPath, JSON.stringify(host));
  await writeFile(inputPath, JSON.stringify({ url: `${fixture.origin}/quotes` }));

  await execute("mix", [
    "ptc", "run", join(directory, "boundary.ptc.json"), "--host-config", hostPath,
    "--input", inputPath, "--output", resultPath,
    "--inspect", inspectPath,
    "--trace-dir", tracePath,
  ], {
    cwd: repository,
    env: { ...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin },
    timeout: 300_000,
    maxBuffer: 8 << 20,
  });

  const result = JSON.parse(await readFile(resultPath, "utf8"));
  assert.match(result.first, /Measure the change before changing the measure/);
  assert.match(result.first, /Ada North/);
  assert.match(result.second, /A useful question leaves room for evidence/);
  assert.match(result.second, /Ben West/);
  assert.equal(typeof result.first_next_cursor, "string");
  assert.equal(result.second_next_cursor, null);
  process.stdout.write("ptc-web HTML extraction and pagination survived the wrapper\n");
} finally {
  await fixture.close();
}
