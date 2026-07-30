# MCP Dynamic Client Registration compatibility

**Status:** future, trigger-gated. Dynamic Client Registration is deprecated
in the final MCP `2026-07-28` authorization profile and retained there only for
backward compatibility with authorization servers that do not support Client
ID Metadata Documents.

The active OAuth plan supports pre-registered clients, Client ID Metadata
Documents, and validated manual registration input. Those mechanisms cover the
preferred MCP registration paths and providers such as Google that issue
console-managed OAuth clients. DCR is not part of the first implementation
because safe registration creation requires a durable state machine much
larger than the interoperability benefit currently demonstrated.

## Trigger

Start this work only when a concrete important MCP server:

- supports neither Client ID Metadata Documents nor practical
  pre-registration;
- advertises conforming DCR;
- is required by a first-party application or demonstrated user deployment;
  and
- cannot be supported through validated manual registration input.

An abstract compatibility goal or the presence of a registration endpoint is
not enough.

## Required authority and storage shape

The design must remain host-enabled and fail closed. The first supported DCR
profile should register public clients with
`token_endpoint_auth_method: "none"` only; generated confidential-client
secrets remain out of scope until a separate lifecycle is justified.

DCR requires an authorization-store adapter that advertises encrypted durable
registration capability. The shipped transient in-memory store must reject DCR
before dispatch. Registration state is authority-shared, not principal-owned:
all principals under one active installation authority use the same registered
client identity while their grants remain principal-scoped. The registration
key is at least
`{tenant_id, installation_id, authority_fingerprint, authority_epoch, issuer,
client_metadata_hash}`. It cannot be loaded through another tenant, authority
epoch, or metadata version.

Creation requires one exclusive bounded lease per registration key:

1. acquire the lease and reload any existing registration;
2. persist `not_dispatched`, then atomically persist `dispatched` before the
   registration request reaches the network adapter;
3. never retry a possibly dispatched registration POST;
4. conditionally commit a validated client identity against the lease and
   starting version; and
5. leave `registration_indeterminate` after any possibly dispatched failure or
   owner death so another node cannot create a duplicate client until an
   explicit operator reconciliation resolves it.

A proven pre-dispatch failure may release an empty record. Registration
responses must be bounded and contain no client secret in the public-client
profile. When the server returns a registration management URI and access
token, retain them only in the encrypted durable adapter, never in the grant,
events, logs, status, or public output. Use them for bounded authenticated
cleanup when the client metadata is replaced or the installation is retired.

Authority retirement atomically blocks new creation dispatch and captures
every creation record for that authority in its durable intent. A
`not_dispatched` creation may be cancelled and removed. A creation already
marked `dispatched` is a retirement drain record: lease or request expiry is
not proof that its POST stopped or failed, and authority retirement cannot
complete until it receives an acknowledged terminal transport result or the
worker is irreversibly fenced. Its only retiring-state terminal transition
never publishes the registered client. An exact validated successful
registration response stores its client identity and management credential
only in an encrypted cleanup record and immediately enrolls that record in the
same retirement intent's cleanup sub-transition. Any possibly dispatched
failure, response loss, or result that cannot prove whether a client was
created becomes `registration_indeterminate` and blocks retirement pending the
audited operator reconciliation below. Thus a registration POST that crosses
retirement begin can neither become live authority nor be silently orphaned.

RFC 7591 provides no portable lookup for a response lost after client
creation, so `registration_indeterminate` is not automatically retried or
cleared. Provide an explicit audited operator reconciliation API that can:

- attach a client identity and management credential recovered out of band;
- record that the orphan was deleted in the provider console and reset the
  registration key; or
- force-reset only after an explicit acknowledgement that an unreachable
  orphan client may remain.

Metadata replacement and installation replacement/release must delete each old
authority-shared registration when retained management credentials make that
possible. Principal retirement deletes only that principal's grants and flows;
it never deletes or mutates the shared registration used by other principals.
Registration cleanup never races an active authority. Begin the active plan's
durable authority-retirement intent first so ordinary authorization,
registration creation, grant mutation, and MCP/OAuth dispatch are blocked for
that authority. DCR then extends that exact intent with one named cleanup
sub-transition for each registration key under the retiring authority. Each
sub-transition carries the retiring tenant/installation identity, authority
fingerprint and epoch, intent identity, exact registration key, and starting
registration version; it carries no principal identity. The only registration
mutations allowed while retiring are the cleanup-only terminalization of an
already-dispatched creation described above and these intent-authorized cleanup
sub-transitions. Neither can create or publish client/grant authority, and
every creation drain and registration cleanup must finish before
authority-retirement completion. Cleanup before retirement begin or outside
that intent is forbidden. If cleanup is unavailable or cannot complete, the
intent stops with an operator-cleanup-required state; it never silently
abandons a known client or permanently bricks the key without a documented
recovery action.

Within that retirement sub-transition, deletion has its own exclusive bounded
cleanup lease and durable
`delete_not_dispatched`, `delete_dispatched`, `delete_completed`, and
`cleanup_indeterminate` provenance. Persist `delete_dispatched` immediately
before handing the exact management URI and credential to the network adapter.
Only the exact RFC 7592 success response, `204 No Content`, commits
`delete_completed`. A `202`, `404`, `401`, or `403` is not proof of completed
deletion: work may still be pending, the endpoint may be wrong or masked, or
the management credential may be invalid. A proven pre-dispatch failure may
release the cleanup lease without changing the registration. Response loss,
timeout, owner death, any non-204 response, or any other possibly dispatched
result leaves `cleanup_indeterminate`, blocks replacement publication and
retirement completion, and never restores an assumption that the registration
exists.

The default worker does not automatically retry an indeterminate DELETE.
Only the explicit audited reconciliation API may retry the same idempotent
DELETE with the retained exact management identity, after recording operator
intent. Only an exact `204` then completes cleanup; another result remains
indeterminate. Reconciliation may alternatively record out-of-band proof that
the registration is absent. It may not treat `202`, `404`, an authentication
failure, or an unreachable management endpoint as successful cleanup.

## Future slices

1. Revalidate actual server demand and the then-current MCP/DCR specifications.
2. Extend the store capability contract and implement creation
   and deletion lease/provenance recovery, encrypted management-credential
   retention, and audited reconciliation/reset with an encrypted durable test
   adapter. Test response loss before and after DELETE dispatch, the terminal
   exact-204 case, non-terminal 202/404/401/403 responses, blocked
   replacement/retirement, explicit same-identity retry, rejection of cleanup
   outside an authority-retirement intent, one cleanup per shared registration,
   principal retirement leaving the registration intact for other principals,
   tenant/authority-epoch isolation, and cleanup racing ordinary registration
   or authorization activity at authority-retirement begin. Race retirement
   immediately before and after creation dispatch: a pre-dispatch loser sends
   no POST, a successful dispatched winner publishes no authority and is
   cleaned up, and a lost or indeterminate response blocks retirement until
   audited reconciliation.
3. Add bounded public-client registration, native/web redirect classification,
   refresh-grant negotiation, managed cleanup, orphan-warning documentation,
   and live interoperability.

Every slice must preserve the active OAuth plan's SSRF, deadline, redaction,
principal isolation, and no-transparent-replay contracts, pass
`mix precommit`, and receive a clean independent review.
