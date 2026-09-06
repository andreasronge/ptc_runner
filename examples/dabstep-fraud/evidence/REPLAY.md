# Replay acceptance for #1799

Verified on 2026-09-06 with the source-checkout CLI, `ptc-fs-mcp@0.3.0`,
`inputs/luna.json`, and the unchanged application and model prompts. The
mission heap remained 5,000,000 words (40 MB on this machine).

## Recording provenance

The first live sample, `cmd-2tkhszqnm7g1kk95k2qv1s0xt0`, used six model calls
($0.004759), but its analyzer measurements disagreed. The workflow withheld
the answer as `Not Applicable`. A fresh-process replay,
`cmd-1hfy5mbmp0hm6we60m9fvwqvkh`, reproduced that result and the same reviewer
observations. It was not selected for the shipped successful demo.

The shipped recording is `cmd-41epjevy1433hwrfp1qjd839s9`: 11 Luna calls
($0.006097), four analysis evaluations, six recheck evaluations, one review,
and 171 filesystem reads. All three measurements agree on `B. BE`. The
reviewer's caveat about raw volume versus fraud ratio remains in the output.

The first analysis tried to retain the whole table and was heap-killed. The
first recheck program printed `fraud-definition` and a complete page map;
its next model request (inspection input sequence 327) contains a non-null
`next_cursor`, including its signed upstream value. Its request hash is
`sha256:5b25dcfac64a81a34d070ee84816f659a04cac4a380a54c1bcd99d3d9ebc72e5`.
This is a recording of exploratory feedback, not only terminal programs.

`record-replay.sh` extracted every successful model exchange through
`private-run-analysis-v2`. The fixture is 9,623 bytes and has 10 distinct
hashes representing 11 responses. The shared initial request retains an
ordered pair of responses. Its SHA-256 is
`adf24da68c11620f55997deca84c697f92ed90e052beca958c50ecd65b35ad17`.
Exact matching was not weakened.

## Checks

- Fresh processes: `cmd-5cban82yn0yh55tmyb3krge25f` completed with the same
  result and 11 replayed model calls, including the heap correction and the
  cursor-bearing request. The live CLI and its providers had exited first.
- Rebuilt CSV: `cmd-23zzbpjwyf539z6de7b7nqfb1y` completed with the same
  result and 11 calls in another fresh CLI process. The replacement inode was
  386004461 instead of 386004459; the CSV still hashed to
  `5fbb26210a45427d7a6560cfab3a362a08e4067f27cd03695f211a51c47ffc25`.
- One-byte mutation at EOF: `cmd-4865c5k9vwgzz8n90nsxssj5nm` failed with
  exit 5 and `execution/explicit_failure`. The first page's data was unchanged,
  but the second recheck request changed to
  `sha256:5e08022af9c0ad6272342de38cad84edf101b71dcf498e622125d4ed73ec0c74`.
  Private analysis confirmed `not_found` with no matching replay fixture. No
  answer was accepted, and the isolated CSV was restored afterward.
- Extracting the fresh-process replay with `record-replay.sh` produced a
  byte-identical fixture (`cmp`), including all exact request hashes.
- The existing heap-stability regression in `agent_library_test.exs` passes:
  correction request bytes and hashes, and retained execution summaries,
  remain identical across different measured baselines.
- Filesystem integration tests pass against the upgraded 0.3.0 test helper.
  The tutorial was also initialized afresh, checked with passive and active
  doctor, and run live. It returned the Project Lantern owner, risk and next
  checkpoint through the upgraded filesystem tool.
- `mix precommit`, ExDoc with warnings as errors, published-link verification
  and the guide budget check pass. Generated site pages were refreshed.
- The full nightly run passed its other 30 tests. After correcting the new
  test's error-tuple assertion, its focused rerun passed in 367.5 seconds.
  The final test source also compiles without the bitstring pin warning.
- A direct stdio probe of 0.3.0 over a 100,000-byte sample file verified
  same-key fresh-process resume, identical replacement, different-key
  rejection, changed-byte rejection, default process affinity, and missing-key
  startup refusal. Every call used a fresh server process.
- The upstream [0.3.0 release](https://github.com/andreasronge/ptc-fs-mcp/releases/tag/v0.3.0)
  covers default process affinity, same-key deterministic traversal,
  missing/different-key rejection, changed bytes and hashing ceilings.

## Friction and bounded evidence

- The first PR push exposed a 100 ms deadline in the exception-projection
  comparison test. Under the full suite, the captured path timed out while the
  plain path raised as expected; the exact test passed alone with seed 562444.
  This non-timing assertion now uses a 5 s deadline and explicitly requires an
  exception result, so two matching timeouts cannot satisfy it.
- Deterministic hashing defaults to 16 MiB, below this CSV's size. The host
  now supplies a 24,000,000-byte hashing ceiling. This is a server work budget,
  separate from the PTC-Lisp heap; neither limit was made unbounded.
- The successful run retains 729,339 bytes of private inspection and 165,301
  bytes of canonical trace. The fixture is much smaller because it retains
  model responses, not entire request histories or filesystem payloads.
- Both live recordings can be extracted together through the existing helper
  under the analysis profile's unchanged 1,250,000-word heap. The combined
  fixture is 15,220 bytes. This checks a real two-run cohort, not an unbounded
  trace archive.
- Select finished runs with `--run` before paging through their collections.
  Trying to capture a directory during an active run reported
  `source_unavailable`. For larger collections use `analysis/open` to discover
  filters, then `analysis/read` with top-level filters and a small `limit`;
  reduce each page to the fields needed instead of retaining every exchange.
- The command-level nightly tests now copy example files and inputs into
  temporary directories, excluding accumulated trace and inspection archives.
  Each replay creates fresh providers, and test outputs stay under the
  test temporary directory instead of growing the example's default archive.
  Full replay, replacement and mutation coverage stays tagged `:nightly`: it scans
  the entire CSV repeatedly and is intentionally not an ordinary unit test.
- The first nightly pass exposed a test-authoring mistake: an expected
  failed command returns `{:error, outcome}`, not `{:ok, outcome}`. The
  mutation had failed closed correctly; the assertion was corrected.
- A manual private-output destination under `/tmp` was refused before the
  analysis session opened. The recording helper's owner-only staging directory
  worked, without changing the profile or its limits.
- A failed command can still publish its envelope. Reusing that filename
  reports `envelope_destination_exists`; use a distinct filename per probe.
- `transport.env` requires `{"binding":"cursor_key"}`. The validator caught
  an attempted `credential` field with a precise missing-binding diagnostic.
- Portable checked-in fixtures require a shared key. `replay-cursor-key.txt`
  is intentionally public trusted-playback material; it offers no protection
  against a client that uses it to forge cursors. Private live runs bind a
  secret `DABSTEP_CURSOR_KEY`, kept outside the model's read surface.
