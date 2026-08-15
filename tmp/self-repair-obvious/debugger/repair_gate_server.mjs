import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import {spawnSync} from "node:child_process";

const [manifestPath, runnerRoot, artifactRoot] = process.argv.slice(2);
fs.mkdirSync(artifactRoot, {recursive: true, mode: 0o700});

function reply(id, result) {
  process.stdout.write(JSON.stringify({jsonrpc: "2.0", id, result}) + "\n");
}

function fail(id, message) {
  reply(id, {
    resultType: "complete",
    isError: true,
    content: [{type: "text", text: message}]
  });
}

function complete(id, value) {
  reply(id, {resultType: "complete", structuredContent: value, content: []});
}

function checkCandidate(args) {
  const required = [
    "target_environment",
    "target_mission",
    "component_id",
    "base_source_hash",
    "candidate_source"
  ];
  if (!args || required.some((key) => typeof args[key] !== "string" || args[key].length === 0)) {
    return {
      accepted: false,
      outcome: "invalid-request",
      diagnostics: "all candidate fields must be non-empty strings"
    };
  }
  if (!['workflow', 'mission'].includes(args.target_environment)) {
    return {
      accepted: false,
      outcome: "invalid-request",
      diagnostics: "target_environment must be workflow or mission"
    };
  }

  const attemptRoot = fs.mkdtempSync(path.join(artifactRoot, "attempt-"));
  fs.chmodSync(attemptRoot, 0o700);
  const sourcePath = path.join(attemptRoot, "candidate.clj");
  const outputPath = path.join(attemptRoot, "materialized");
  fs.writeFileSync(sourcePath, args.candidate_source, {
    encoding: "utf8",
    mode: 0o600,
    flag: "wx"
  });

  const targetArgs = args.target_environment === "workflow"
    ? ["--workflow"]
    : ["--target-mission", args.target_mission];
  const checked = spawnSync("mix", [
    "ptc.materialize",
    manifestPath,
    ...targetArgs,
    "--component",
    args.component_id,
    "--out",
    outputPath,
    "--source",
    sourcePath
  ], {
    cwd: runnerRoot,
    encoding: "utf8",
    timeout: 30000,
    maxBuffer: 256 * 1024
  });
  const diagnostics = `${checked.stdout || ""}${checked.stderr || ""}`.trim().slice(0, 12000);
  if (checked.error) {
    return {
      accepted: false,
      outcome: "gate-unavailable",
      diagnostics: checked.error.message.slice(0, 1000)
    };
  }
  if (checked.status !== 0) {
    return {accepted: false, outcome: "materialize-refused", diagnostics};
  }

  const descriptor = JSON.parse(fs.readFileSync(path.join(outputPath, "descriptor.json"), "utf8"));
  if (descriptor.base_source_hash !== args.base_source_hash) {
    return {
      accepted: false,
      outcome: "base-hash-mismatch",
      diagnostics: `captured base ${args.base_source_hash} does not match selected base ${descriptor.base_source_hash}`
    };
  }
  if (descriptor.source_hash === descriptor.base_source_hash) {
    return {
      accepted: false,
      outcome: "no-op",
      diagnostics: "candidate source hash equals the selected base source hash"
    };
  }
  return {
    accepted: true,
    outcome: "accepted",
    diagnostics,
    base_source_hash: descriptor.base_source_hash,
    source_hash: descriptor.source_hash
  };
}

const inputSchema = {
  type: "object",
  additionalProperties: false,
  required: [
    "target_environment",
    "target_mission",
    "component_id",
    "base_source_hash",
    "candidate_source"
  ],
  properties: {
    target_environment: {type: "string", enum: ["workflow", "mission"]},
    target_mission: {type: "string", minLength: 1},
    component_id: {type: "string", minLength: 1},
    base_source_hash: {type: "string", minLength: 1},
    candidate_source: {type: "string", minLength: 1, maxLength: 131072}
  }
};

const outputSchema = {
  type: "object",
  additionalProperties: false,
  required: ["accepted", "outcome", "diagnostics"],
  properties: {
    accepted: {type: "boolean"},
    outcome: {type: "string"},
    diagnostics: {type: "string"},
    base_source_hash: {type: "string"},
    source_hash: {type: "string"}
  }
};

const reader = readline.createInterface({input: process.stdin, crlfDelay: Infinity});
reader.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  const {id, method, params} = message;
  if (method === "server/discover") {
    reply(id, {
      resultType: "complete",
      supportedVersions: ["2026-07-28"],
      capabilities: {tools: {}},
      _meta: {"io.modelcontextprotocol/serverInfo": {name: "ptc-repair-gate", version: "0.1.0"}},
      ttlMs: 0,
      cacheScope: "private"
    });
  } else if (method === "tools/list") {
    reply(id, {
      resultType: "complete",
      tools: [{
        name: "check_candidate",
        description: "Compile and gate a complete component replacement against its selected base.",
        inputSchema,
        outputSchema
      }],
      ttlMs: 0,
      cacheScope: "private"
    });
  } else if (method === "tools/call" && params?.name === "check_candidate") {
    try {
      complete(id, checkCandidate(params.arguments));
    } catch (error) {
      fail(id, `repair gate failed: ${String(error?.message || error).slice(0, 1000)}`);
    }
  } else if (id !== undefined) {
    fail(id, "unsupported request");
  }
});
