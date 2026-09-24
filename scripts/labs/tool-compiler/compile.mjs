// Arm C: compile the recipe instead of writing it. The compiler workflow reads
// each page's text, probes candidate selectors against the page itself, and
// returns a candidate recipe. This driver independently executes that candidate
// on every fixture and promotes it only after all checks pass.
//
//   node compile.mjs [--env-file /absolute/path/to/.env]
//
import { execFile } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { promoteCandidate, recordsAreCorrect, validRecipe } from "./driver.mjs";
import { expected, startFixture } from "./fixture.mjs";

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
const candidateManifestPath = join(directory, "compiled/.candidate.ptc.json");
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
      validation_url: `${fixture.origin}/validation`,
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
  const spend = usage.llm_spend ?? {};
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
    `compile cost   ${spend.state === "incomplete" ? "n/a" : `${spend.input ?? 0} in / ${spend.output ?? 0} out / ${spend.total_cost?.microunits ?? 0} microUSD`}\n`,
  );
  process.stdout.write(`recipe         ${JSON.stringify(recipe)}\n`);

  const compilationSucceeded = status === "ok" && envelope.status === "ok";
  const verificationRows = [];

  if (compilationSucceeded && validRecipe(recipe)) {
    const acceptedManifestPath = join(directory, "compiled/ptc.json");
    const candidateManifest = JSON.parse(
      await readFile(acceptedManifestPath, "utf8"),
    );
    candidateManifest.missions.default.data = { recipe };
    await writeFile(
      candidateManifestPath,
      `${JSON.stringify(candidateManifest, null, 2)}\n`,
    );

    for (const path of Object.keys(expected)) {
      const name = `verify-${path.slice(1)}`;
      const verifyInput = join(output, `${name}-input.json`);
      const verifyResult = join(output, `${name}-result.json`);
      const verifyEnvelope = join(output, `${name}-envelope.json`);
      const verifyTraces = join(output, `${name}-traces`);
      await mkdir(verifyTraces, { mode: 0o700 });
      await writeFile(
        verifyInput,
        JSON.stringify({ task: "verify", url: `${fixture.origin}${path}` }),
        { mode: 0o600 },
      );

      let verifyStatus = "ok";
      try {
        await execute(
          process.env.PTC ?? "ptc",
          ["run", candidateManifestPath, "--host-config", hostPath,
           "--input", verifyInput, "--output", verifyResult,
           "--envelope", verifyEnvelope, "--trace-dir", verifyTraces],
          {
            cwd: directory,
            env: { ...process.env, PTC_WEB_FIXTURE_ORIGIN: fixture.origin },
            timeout: 600000,
            maxBuffer: 8 << 20,
          },
        );
      } catch (error) {
        verifyStatus = "failed";
        process.stderr.write(`${name}: ${error.stderr || error.message}\n`);
      }
      const checkedEnvelope = await readFile(verifyEnvelope, "utf8")
        .then(JSON.parse)
        .catch(() => ({}));
      const checkedValue = await readFile(verifyResult, "utf8")
        .then(JSON.parse)
        .catch(() => null);
      verificationRows.push({
        page: path,
        status:
          verifyStatus === "failed"
            ? verifyStatus
            : (checkedEnvelope.status ?? verifyStatus),
        correct: recordsAreCorrect(expected[path], checkedValue?.records),
      });
    }
  }

  process.stdout.write(`verification   ${JSON.stringify(verificationRows)}\n`);
  const promotion = await promoteCandidate({
    acceptedManifestPath: join(directory, "compiled/ptc.json"),
    candidate: recipe,
    compilationSucceeded,
    expected,
    verificationRows,
  });
  if (promotion.promoted) {
    process.stdout.write(`\npromoted the independently verified recipe to compiled/ptc.json\n`);
  } else {
    process.stdout.write(`\n${promotion.reason}; compiled/ptc.json untouched\n`);
    process.exitCode = 1;
  }
} catch (error) {
  failure = error;
} finally {
  await rm(candidateManifestPath, { force: true });
  await fixture.close();
}

if (failure) {
  process.stderr.write(`${failure.stack ?? failure}\n`);
  process.exitCode = 1;
}
