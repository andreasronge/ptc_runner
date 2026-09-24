// Arm C: compile the recipe instead of writing it. The compiler workflow reads
// each page's text, probes candidate selectors against the page itself, and
// returns a recipe. This driver then writes that recipe into the compiled arm's
// mission data, so the compiled artifact is data rather than generated source.
//
//   node compile.mjs [--env-file /absolute/path/to/.env]
//
// Verify afterwards with `ARMS=compiled node run.mjs`, which re-extracts every
// page with the recipe this produced.
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { startFixture } from "./fixture.mjs";
import { formatSpend, usageOf } from "./reporting.mjs";

const execute = promisify(execFile);
const directory = dirname(fileURLToPath(import.meta.url));
const envFlag = process.argv.indexOf("--env-file");
const envFile = envFlag === -1 ? null : resolve(process.argv[envFlag + 1]);

async function commandPath(name) {
  for (const candidate of (process.env.PATH ?? "").split(delimiter)) {
    try {
      if ((await readdir(candidate)).includes(name)) return join(candidate, name);
    } catch {}
  }
  throw new Error(`${name} is not available on PATH`);
}

const output = await mkdtemp(join(directory, ".arm-c-"));
const fixture = await startFixture();
let failure;

try {
  const packages = join(output, "packages");
  await execute(
    await commandPath("npm"),
    ["install", "--prefix", packages, "--no-save", "--no-audit", "--no-fund",
     "--package-lock=false", "ptc-web@0.1.0"],
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

  const inputPath = join(output, "input.json");
  const resultPath = join(output, "recipe.json");
  const envelopePath = join(output, "envelope.json");
  const traceDir = join(output, "traces");
  await mkdir(traceDir, { mode: 0o700 });
  await writeFile(
    inputPath,
    JSON.stringify({
      learn_url: `${fixture.origin}/quotes`,
      holdout_url: `${fixture.origin}/held-out`,
    }),
    { mode: 0o600 },
  );

  let status = "ok";
  try {
    await execute(
      process.env.PTC ?? "ptc",
      ["run", "compiler/ptc.json", "--host-config", hostPath,
       "--input", inputPath, "--output", resultPath,
       "--envelope", envelopePath, "--trace-dir", traceDir,
       "--inspect", join(output, "compile.ptcins"),
       ...(envFile ? ["--env-file", envFile] : [])],
      {
        cwd: directory,
        env: { ...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin },
        timeout: 900000,
        maxBuffer: 8 << 20,
      },
    );
  } catch (error) {
    status = "failed";
    process.stderr.write(`${error.stderr || error.message}\n`);
  }

  const envelope = await readFile(envelopePath, "utf8")
    .then(JSON.parse)
    .catch(() => ({}));
  const usage = envelope?.execution?.usage ?? {};
  const reportedUsage = usageOf(envelope);
  const recipe = await readFile(resultPath, "utf8")
    .then(JSON.parse)
    .catch(() => null);

  process.stdout.write(`\nArm C: compiling the recipe\n\n`);
  process.stdout.write(`status         ${envelope.status ?? status}\n`);
  process.stdout.write(
    `probe calls    ${Object.entries(usage.capability_calls ?? {})
      .filter(([key]) => !key.endsWith("/llm-request"))
      .map(([key, count]) => `${key.replace(/^mission\//, "")}=${count}`)
      .join(" ") || "none"}\n`,
  );
  process.stdout.write(
    `model calls    ${usage.capability_calls?.["workflow/llm-request"] ?? 0}\n`,
  );
  process.stdout.write(
    `compile cost   ${formatSpend(reportedUsage)}\n`,
  );
  process.stdout.write(`recipe         ${JSON.stringify(recipe)}\n`);

  if (recipe?.container && recipe?.text_selector && recipe?.author_selector) {
    const manifestPath = join(directory, "compiled/ptc.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.missions.default.data = { recipe };
    await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    process.stdout.write(
      `\nwrote the recipe into compiled/ptc.json mission data.\n` +
        `verify with: ARMS=compiled node run.mjs\n`,
    );
  } else {
    process.stdout.write(`\nno usable recipe; compiled/ptc.json untouched\n`);
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
