# Replay cursor measurements

The benchmark exercises the shared replay owner directly with one request hash,
one or four independent run scopes, and ordered map responses. It consumes the
first response before measurement, then drains the rest and checks exhaustion.
Four scopes drain concurrently through the same serialized owner. Fixture loading
and hashing are excluded; small rows include task dispatch overhead.

Run from the repository root:

```sh
mix run bench/replay_cursor.exs
```

For the baseline, use the script from this change with
`lib/ptc_runner/kernel/llm_replay_owner.ex` from commit `96a1aea76`.
The following single samples were collected on the same managed Linux worker,
with Elixir 1.20.2, OTP 29 (ERTS 17.0.3), and four BEAM schedulers. Times are observations, not test thresholds.
Owner reductions expose lookup scaling independently of scheduling noise.
Memory is owner process bytes after explicit full garbage collection: loaded
fixtures, active cursors after one take each, and exhausted cursors. It includes
heap capacity and is not a precise live-term size or whole-VM peak.

| Length | Runs | Before µs | After µs | Before reductions | After reductions | Before bytes loaded/active/drained | After bytes loaded/active/drained |
| ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 1 | 1 | 36 | 34 | 38 | 27 | 2792/2864/2864 | 2792/2864/2864 |
| 1 | 4 | 58 | 54 | 152 | 108 | 2792/4224/4224 | 2792/4224/4224 |
| 10 | 1 | 33 | 40 | 479 | 306 | 2792/2864/4008 | 2792/2864/4008 |
| 10 | 4 | 97 | 92 | 1771 | 1076 | 2792/4224/4224 | 2792/4224/4224 |
| 1000 | 1 | 2335 | 1549 | 542203 | 29664 | 55104/88664/88664 | 55104/88664/88664 |
| 1000 | 4 | 9198 | 4936 | 2161088 | 114937 | 55104/88880/88880 | 55104/88880/143064 |
| 10000 | 1 | 87703 | 17614 | 50419044 | 294041 | 601832/973288/973288 | 601832/973288/601904 |
| 10000 | 4 | 395395 | 70013 | 201515453 | 1120441 | 601832/973504/973504 | 601832/973504/973504 |
| 40000 | 1 | 1410343 | 65742 | 801679627 | 1166105 | 2546424/4119704/2546496 | 2546424/4119704/4119704 |
| 40000 | 4 | 5543711 | 384156 | 3206039882 | 4590701 | 2546424/4119920/4119920 | 2546424/4119920/4119920 |

Increasing length fourfold from 10,000 to 40,000 increases baseline reductions
about sixteenfold, while remaining-tail reductions increase about fourfold.
Shared-owner runs show the same scaling. Small fixtures have comparable timings;
the ten-response single-run sample is slightly slower after the change.

Remaining tails share the owner's immutable source lists. They need one map
entry per touched request per run, without copying the sequence or converting
fixtures to another representation. Measured active memory is identical here;
drained heap capacity varies with garbage collection history. The immutable
source intentionally remains resident for subsequent runs. Run exit removes its
cursor map and monitor; installation exit stops the owner and releases fixtures.
This favors tails over an indexed conversion: constant advancement, no loading
conversion, and no additional full sequence representation.
