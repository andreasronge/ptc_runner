# MCP OAuth durable-store conformance

**Status:** future, adapter-triggered.

The active OAuth implementation defines an atomic store behaviour and ships an
owner-process in-memory adapter. It deliberately does not ship persistent token
storage. Building a filesystem snapshot adapter solely for tests would add an
encryption, fsync, recovery, distributed-clock, and fault-injection protocol
that no production deployment uses and could provide misleading confidence
about a future database-backed host.

Start this work when a concrete hosted or embedding application proposes a
persistent adapter. Make that adapter, or a faithful transactional test double
of its storage engine, the conformance subject.

## Required conformance

The adapter must:

- encrypt and authenticate secret-bearing state at rest with keys held outside
  the state store;
- make every `PtcRunner.Kernel.MCPOAuth.Store.transact/3` operation
  crash-atomic and preserve the behaviour's compare-and-swap, dispatch fence,
  rotation, poisoning, retirement, and tenant/principal isolation contracts;
- make MCP admission release idempotent and drain it from the explicit release
  operation; a durable adapter cannot rely on monitoring the admitting BEAM
  process, which may live on another node or disappear before acknowledgement;
- use an adapter-authoritative clock and accept relative TTLs and opaque time
  anchors without persisting or comparing BEAM monotonic timestamps;
- implement one stable-CLI Store mutation mode explicitly: either negotiate an
  opaque adapter-issued transaction guard whose server-clock expiry includes a
  proven clock/transport uncertainty margin and is no later than the caller
  deadline, then recheck it atomically before commit, or classify every timeout
  after possible mutation dispatch through the Store command catalog's required
  stable-idempotency/authoritative-only, post-dispatch-projection, and
  cleanup-action fields; a submitted remaining duration alone is not an
  authoritative remote deadline, and no mutation may use an uncatalogued
  fallback;
- expose the selected mutation mode as inert store-handle metadata so runtime
  service construction can reject an indeterminate adapter when any exported
  Store mutation is `authoritative_only`, before any store call or provider
  activity; all production calls must use the catalog-generated Store wrappers,
  never construct a command or invoke `transact/3` directly;
- recover only committed state and fail closed on missing, corrupt, mismatched,
  or rolled-back records; and
- remain safe across multiple caller nodes with unrelated monotonic origins
  and skewed wall clocks.

Fault injection must cover process or node death before and after every
transaction publication and reply boundary, including batch authority claims,
grant/requirement changes, refresh rotation, pending-flow consumption, and
bulk retirement. It must also delay requests and replies beyond the caller's
local deadline: authoritative guards reject late commits using only the store
clock, while indeterminate-mode adapters drive every exported mutation through
its catalog projector and cleanup action and never report a possibly dispatched
mutation as unchanged. Restart tests must prove remaining lifetimes never
increase, an old refresh token cannot be spent concurrently, and a possibly
dispatched mutation cannot become usable after recovery.

If the concrete adapter uses whole-state files, use immutable encrypted
snapshots plus a separately fsynced version-and-digest commit marker:
same-directory temporary write, file sync, atomic rename, directory sync,
marker temporary write and sync, marker rename, and a final directory sync
before reply. Recovery loads only the authenticated snapshot named by the last
valid marker and ignores uncommitted newer files. Database-backed adapters
should instead test the equivalent native transaction and durability
boundaries rather than imitate this file protocol.
