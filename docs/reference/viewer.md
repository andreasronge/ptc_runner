# Viewer HTTP API

This reference inventories the Viewer's public HTTP routes, their availability, important failures, and security boundaries.

The Viewer is included in the standalone executable and container image. It is
an optional companion that is absent from the published library package. Start
it with `ptc viewer PROJECT`; the project selects the trace and private
inspection sources and whether the REPL is available. Normal Viewer startup
provides Live ingestion; project details and launch controls appear only when
their corresponding host configuration is available.

## Network and security boundary

The server binds `127.0.0.1` by default. `--listen 0.0.0.0` is the only
non-loopback bind and prints an exposure warning. The Viewer has no general
authentication layer: anyone who can reach it can browse the selected traces
and any private inspection records the project grants. In a container, bind
the server to `0.0.0.0` but publish the host port on loopback, for example
`-p 127.0.0.1:4123:4123`. Publishing an unrestricted host port exposes the
trace browser.

These route families have separate boundaries:

- **Trace browsing** (`/api/kernel/*`) reads the pinned trace snapshot. It has
  no per-request authentication. Refresh is available only when the host
  supplies a refresh callback.
- **Private analysis** (`/api/analysis/*`) reads only inspection records that
  the project selected and explicitly granted as private. The routes return
  `404` reason codes when the run, project configuration, or private grant does
  not authorize evidence. They have no additional HTTP authentication.
- **REPL** (`/api/repl*`) exists only when the project enables the analysis
  REPL. Bootstrap requires a page loaded from the same Viewer and its
  page nonce. Mutations require the exact `localhost` or `127.0.0.1` host and
  Viewer port, an exact same-origin `Origin`, the session precondition, and the
  session mutation nonce. These checks prevent another browser origin from
  driving the local REPL; they do not make it a remote authenticated API.
- **Live browser controls** (`/api/live/*`, except ingestion) require a browser
  host of `localhost`, `127.0.0.1`, or `::1`. Mutations also require an exact
  same-origin `Origin` and the page's `X-PTC-Viewer-Live-Nonce`. A loopback peer
  is accepted directly. A non-loopback peer must authenticate with the Live
  token.
- **Live reporters** use `POST /api/live/runs/:run_id`. Loopback reporters need
  no token when none is configured. When `PTC_VIEWER_TOKEN` configures a token,
  reporters send it as `Authorization: Bearer ...`; non-loopback reporters
  always need the configured token.

`PTC_VIEWER_URL` on `ptc run` names the Viewer that receives best-effort Live
frames. `PTC_VIEWER_TOKEN` configures the Viewer token and is also read by an
external reporter. Tokens must contain at least 32 bytes. For a browser whose
network peer is not loopback, open `/?live_token=TOKEN#/live` once; the page
removes the query parameter and uses the token for Live reads and mutations.
The server-sent-event request retains an encoded query token because browser
`EventSource` cannot set an authorization header.

The Live token protects Live ingestion and controls only. It does **not**
protect the Runs tab, trace routes, private-analysis routes, static assets, or
the Viewer as a whole. Do not treat it as authentication for remote hosting.

Security failures on configured REPL and Live routes return `403`. Unsupported
methods on configured REPL routes return `405`. A disabled REPL returns `404`;
unavailable Live features generally return `503`. Successful JSON responses
use `application/json`; successful private-analysis responses and all REPL
responses are non-cacheable. Route-specific behavior follows.

## Trace and private-analysis routes

| Route | Purpose, availability, and important behavior |
| --- | --- |
| `GET /api/kernel/runs` | List the pinned runs with bounded filters and pagination. `limit` is decoded as an integer and `tags` as a JSON object before all query parameters are passed to `Kernel.TraceLog`. Invalid queries return `400`; adapter faults return `500`; unavailable or changing sources return `503` or `409`; oversized or unsupported sources return `413` or `422`. |
| `POST /api/kernel/refresh` | Recapture the host snapshot without a run ID. Returns `503` when refresh is unavailable, `404` when the selected source is not found, and `500` when refresh fails. |
| `GET /api/kernel/runs/:run_id` | Return one run. Returns `404` when absent and otherwise uses the trace-query failure statuses above. |
| `GET /api/kernel/runs/:run_id/turns` | List one run's turns with bounded filters and pagination. Uses the trace-query failure statuses above. |
| `GET /api/kernel/counters` | Return bounded counters for the pinned snapshot. Uses the trace-query failure statuses above. |
| `GET /api/analysis/runs/:run_id/conversation` | Present the bounded conversation derived from turns. Requires a selected private inspection projection. |
| `GET /api/analysis/runs/:run_id/preludes` | Return bounded effective prelude sources from the pinned private inspection projection. |
| `GET /api/analysis/runs/:run_id/execution-errors` | Return authorized workflow execution-error records from the pinned private inspection projection. |
| `GET /api/analysis/runs/:run_id/explicit-failure-values` | Return dedicated explicit-failure-value records from the pinned private inspection projection. |

Private-analysis routes distinguish unrecorded or mismatched runs, missing
inspection configuration, and a missing private grant with specific `404`
reason bodies. They return `503` for unavailable sources, `409` if a source
changes, `413` if it exceeds its bound, `422` for an unsupported artifact,
`500` for adapter failure, and `400` for another invalid query.

The kernel routes preserve the TraceLog's not-found, invalid-query,
unavailable-adapter, and adapter-failure classifications. Run listings render
the Kernel's bounded `isolation` object as a damaged-source notice while
retaining any separate source-kind exclusion notice. An isolated run claim is
returned as `422 run_isolated`; direct retained-size refusal is returned as
`413 Trace source retained size exceeded`.

## Analysis REPL routes

| Route | Purpose, availability, and important behavior |
| --- | --- |
| `GET /api/repl` | Bootstrap or refresh the server-owned analysis session. Requires the REPL, exact Viewer host and port, `Sec-Fetch-Site: same-origin`, and the page's `X-PTC-Viewer-Page-Nonce`. Returns the session ID and mutation nonce; returns `404` when the REPL is disabled. |
| `POST /api/repl/evaluations` | Evaluate one bounded PTC-Lisp form in the current session. Requires `Content-Type: application/json` and exactly `{"source":"FORM"}`, plus the mutation headers below. |
| `POST /api/repl/templates` | Format an inert `analysis/open` or `analysis/read` editor template. It does not evaluate the template. Requires JSON with exactly `{"kind":"run","run_id":"ID"}` or `{"kind":"turns","run_id":"ID"}`, plus the mutation headers below. |
| `POST /api/repl/reset` | Persist the current session and capture its replacement. Requires the JSON object `{}` and the mutation headers below. |
| `DELETE /api/repl` | Close and persist the current session. Requires an empty body and the mutation headers below. |

Every REPL mutation sends the exact Viewer `Origin`, the current
`X-PTC-Viewer-Session`, and the session's `X-PTC-Viewer-Nonce`. Successful
responses repeat the current session ID in `X-PTC-Viewer-Session` and in the
JSON body. JSON mutation bodies accept no unlisted fields.

REPL responses use stable JSON error codes. Besides `403` and `405`, important
statuses include `400` for malformed requests, `409` for an active operation,
terminal or closed session, or changed trace, `412` when the session changed, `413`
for request, source, or trace bounds, `415` for a non-JSON content type, `422`
for an unsupported trace, `428` when the session precondition is missing,
`503` when the trace is unavailable, and `500` for startup, persistence, or
adapter failures.

## Live routes

Live routes require the host-injected Live store. Project details and launch
controls also require their corresponding project or launch configuration.

| Route | Purpose, availability, and important behavior |
| --- | --- |
| `POST /api/live/runs/:run_id` | Accept one correlated, self-contained JSON object as the reporter frame. The path supplies `run_id`; the store overwrites any body `run_id` and `first_seen_at`. The object must be JSON-encodable. Requires reporter security and `Content-Type: application/json`; returns `503` when Live is disabled and `400` for invalid input. |
| `GET /api/live/runs` | Snapshot retained runs newest first, including `first_seen_at`. Requires Live browser-read security; returns `503` when Live is disabled. |
| `GET /api/live/stream` | Stream the current snapshot and later frames as server-sent events, with heartbeat comments. Requires Live browser-read security; returns `503` when Live is disabled. |
| `DELETE /api/live/runs/:run_id` | Forget one retained run. Requires Live browser-mutation security; returns `404` for an unknown run and `503` when Live is disabled. |
| `POST /api/live/runs/:run_id/inspect` | Refresh the pinned trace snapshot for a completed run. Requires Live browser-mutation security; returns `404` when the run is absent, `503` when refresh is unavailable, and `500` when refresh fails. |
| `GET /api/live/project` | Describe host-injected project details. Requires Live browser-read security and the Live store; returns `200 {"enabled":false}` when the project adapter is absent or fails, and `503` when Live is disabled. |
| `GET /api/live/launch` | Describe the fixed launch target and current status. Requires Live browser-read security. Returns `{"enabled":false}` when no target is configured and `503` when Live is disabled. |
| `POST /api/live/launch` | Launch the fixed workflow with `{"input":{...}}`, or a declared mission with `{"mission":"NAME","expression":"FORM"}`. Requires Live browser-mutation security and JSON. Returns `202` when accepted, `409` while another launch runs, `503` when Live is disabled, and `400` for invalid or oversized input or a missing launch target. |

## Route inventory ownership

This table is the public route catalog. The Viewer test suite compares every
`/api/kernel/*`, `/api/analysis/*`, `/api/repl*`, and `/api/live/*` router
declaration with the routes written here, so either side changing alone fails
the test. Browser entry, static-asset, redirect, and catch-all routes are not
part of this API inventory.
