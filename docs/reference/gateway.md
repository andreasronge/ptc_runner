# Gateway configuration

The loopback gateway loads one fixed set of applications and exposes health
checks.

MCP discovery, request-header authentication, execution, and standalone release
integration are separate delivery steps.

Run the source command from `ptc_gateway/`:

```sh
mix ptc.gateway /absolute/path/ptc-gateway.json --env-file /absolute/path/credentials.env
```

Remote clients need an authenticated tunnel to loopback. Native TLS, proxy
trust, direct private-network binding, and container port publishing are not
supported. Changing configuration, credentials, templates, or pins requires a
whole-domain restart.

## Version 1 contract

`priv/schemas/ptc-gateway-config.schema.json` is generated from
`PtcRunner.Kernel.GatewayConfig.schema/0` by `mix ptc.gen_docs`. The root
staleness gate checks it. The schema and this semantic table are normative.
There is no implicit configuration search or implicit environment-file search.

| Surface | Rule |
| --- | --- |
| JSON | UTF-8, at most 1,000,000 bytes; duplicate and unknown keys rejected at every depth. Strings exclude NUL, CR and LF. Schema string maxima are also byte maxima. |
| Required fields | `version`, `listen`, `authentication`, `host`, `admission`, `tools`; nested requirements are specified by the schema. |
| Version | Exactly `1`. Optional `$schema` has the exact published gateway schema URL. |
| Listener | Literal `127.0.0.1` or `::1`; port 1–65535, fixed path `/mcp`. |
| Origins | `listen.allowed_origins` defaults to `[]`; at most 128 unique HTTP(S) serialized origins, each at most 2048 bytes. No userinfo, path, query, fragment, whitespace, escapes, uppercase host, or explicit default port. |
| Authority | Every request requires exactly the configured literal listener authority, including its port except port 80; IPv6 uses brackets. No proxy headers are trusted. |
| Bearer | `authentication.bearer.binding` names a host credential. The document never carries the bearer value. Capture enforces 32–4096 ASCII bytes in HTTP bearer-token grammar. |
| Admission | `max_inflight_requests`, `max_concurrent_runs`, and `max_active_provider_calls` each require 1–65535; `max_waiting_provider_calls` requires 0–65535. The request limit is supplied to the future MCP transport. |
| Tools | 1–128 entries, unique names matching `[a-zA-Z0-9_.-]{1,128}`, validated in name order. Titles require 1–256 bytes; descriptions 1–4096. |
| Application | `application.manifest` names one manifest file, at most 1024 bytes. The serving constructor requires object input/output contracts and a validated read/write effect. |
| Write permission | `allow_write` defaults to false. A compiled write effect requires true; permission never changes the compiled effect. |
| Content pin | Required `expected_application_content_digest`, exactly `sha256:` plus 64 lowercase hex characters; effective application identity is not interchangeable. |
| Installation pins | Required exact map `installation_config_pins`, keyed by installation name. Missing, extra, stale or mismatched values refuse startup. |
| Snapshot pins | Required exact map `provider_snapshot_pins`, keyed `workflow/name` or `mission/name`. Values pin acquisition identity, never volatile content. Tools without providers require both maps to be empty. |
| Paths | Host, application manifests and audit directory resolve from the gateway document directory. Nested host-owned paths retain host-document-relative semantics. |
| Environment file | Anchored once from the invocation directory. Warm startup captures the bearer and selected provider credentials in one scope, restoring environment and lock before listener binding, including on failure. |
| Private audit | Required iff any tool sets `allow_write: true`; forbidden otherwise. Required fields: `directory`, `max_file_bytes` (1024–67108864), `max_retained_files` (2–128). |

## Pins

From the root project, obtain the two provider pin maps using the existing safe
command. It never runs the workflow and prints no credential or volatile
provider content:

```sh
mix ptc.provider_pins /absolute/path/app.json --host /absolute/path/host.json --env-file /absolute/path/credentials.env
```

An application without providers prints exactly:

```json
{"installation_config_pins":{},"provider_snapshot_pins":{}}
```

Provider-bearing output uses the same keys and `sha256:<64 lowercase hex>`
values. Copy both complete maps into that tool's configuration. Obtain the
application content pin from the root source project without running the
workflow or resolving credentials:

```sh
mix run -e '
with {:ok, host} <- PtcRunner.Kernel.HostConfig.load("/absolute/path/host.json"),
     {:ok, package, _} <- PtcRunner.Kernel.ApplicationPackage.acquire_directory(
       "/absolute/path/app.json", installed_limits: host.limits, omit_input: true) do
  IO.puts("sha256:" <> package.application_content_digest)
else
  _ -> IO.puts(:stderr, "Application pin unavailable"); System.halt(78)
end'
```

The command prints one line, `sha256:<64 lowercase hex>`. Copy it into
`expected_application_content_digest`.

## Private audit directory

Startup rejects symbolic links anywhere in the audit hierarchy and unsafe
ownership or writable ancestry. It creates missing directories as 0700 and
files as 0600 before writing any content. The private directory is exclusively
locked for the owner's lifetime. After an unclean owner death, the retained
lock requires you to stop the old process before removing it.

Each startup durably opens a new numbered file and separately appends and
flushes a temporary probe before readiness. The probe is then removed. Only after the replacement is durable may retention
remove closed files, oldest first. Active files are never truncated. Unexpected
files, hard links, oversized files or wrong permissions refuse startup. There
is no HTTP audit-reading endpoint. Per-call redacted records and execution
failure fencing belong to the execution integration.

## Health

| Request | Response |
| --- | --- |
| `GET /health/live` | 200 `{"status":"live"}` while listener and gateway owner remain alive. |
| `GET /health/ready` | 200 `{"status":"ready"}` when the warm domain is ready; otherwise 503 `{"status":"not_ready"}`. |
| Other method on either health path | 405. `OPTIONS` is unsupported. |
| Other path | 404. |
| Invalid authority, on any path | 400 before routing. |

Health needs no bearer and returns no CORS headers. Responses use
`application/json` and `Cache-Control: no-store`. Readiness uses the warm
runtime's bounded snapshot, including captured credentials, pinned providers,
run admission and provider-call admission. Saturation stays ready; required
runtime loss or fencing makes readiness permanently false while liveness
continues. Invalid static startup configuration prevents listener binding.

## Startup failures

Only the first error is returned. Precedence is document read/JSON, structural
schema and byte bounds, origins, duplicate tool names, audit presence, host,
then each tool's constructor/pin and write permission in name order, audit
filesystem probe, run admission, warm credential capture/provider pins, and
listener binding. A stage must succeed before the next stage runs.

The CLI writes one JSON object `{"error":"<code>"}` and newline to stderr,
nothing to stdout, and exits 78. Successful startup is silent. No names, paths,
credentials, causes or stack traces belong in startup diagnostics.

The finite catalog is `config_unavailable`, `duplicate_json_key`,
`config_invalid`, `origin_invalid`, `tool_name_duplicate`, `audit_invalid`,
`host_invalid`, `template_invalid`, `application_content_digest_mismatch`,
`write_forbidden`, `audit_unavailable`, `run_admission_unavailable`,
`credential_unavailable`, `installation_pin_mismatch`, `provider_pin_mismatch`,
`provider_pin_unavailable`, `provider_admission_unavailable`,
`provider_runtime_unavailable`, `listener_unavailable`, and `internal_error`.
Unrecognized internal failures map to `internal_error`.
