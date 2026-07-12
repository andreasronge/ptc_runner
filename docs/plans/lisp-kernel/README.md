# Lisp Kernel implementation record

The minimal programmable Kernel migration is implemented on
`exp/minimal-kernel`. These documents record the contract and completed
replacement rather than an active exploratory roadmap.

- [`kernel-contract.md`](kernel-contract.md) is the normative V1 runtime
  contract.
- [`tracelog-contract.md`](tracelog-contract.md) defines canonical event
  storage, source grants, bounded queries, and the swappable `log/` library.
- [`kernel-migration.md`](kernel-migration.md) records the completed vertical
  implementation, cutover, deletion, and verification sequence.
- [`kernel-inventory.md`](kernel-inventory.md) is the closed as-built
  retain/migrate/delete record.

Current user-facing material lives in [`../../guides/`](../../guides/). Git
history is the archive for removed experiments and superseded product plans.
