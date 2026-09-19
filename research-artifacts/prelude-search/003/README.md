# Prelude-search 003: deadline calibration

Artifact only; never merge. Authorized by [the frozen protocol](https://github.com/andreasronge/ptc_runner/issues/1996#issuecomment-5744271571).

Source commit: `608c2a92d17a58164357d2d99f0cd201f5d8de7c` ([runtime fix #2020](https://github.com/andreasronge/ptc_runner/pull/2020)). One interval instance, seed 20261020, four existing conditions, 300000 ms per model request. Calibration is excluded from subsequent H1 measurements.

All four cases completed, costing 5864 microusd. Completed-case replay matches candidates, diagnosis, selection, final outcome and reported usage exactly; no new replay spend. The private analysis profile confirms the first model exchange lasted 125898 ms and completed successfully.

`invocation.json` freezes source and command; `live/protocol.json` freezes model, conditions and limits. `live/summary.json` and `result.json` retain measurements. Each model case has separate canonical `traces/` and indexed `inspection/` directories. `replay/` contains network-free re-execution; run `python3 verify-replay.py` to check normalized equality and `python3 build-result.py` to regenerate the report result from retained measurements. Both scripts accept another recording directory as their optional argument. `private-analysis-invocation.json` and `latency-analysis-invocation.json` document the private inspection queries. The original temporary paths identify capture locations; pass the relocated directories to replay and inspection commands.

No comparative H1 verdict is drawn from this single calibration instance. Earlier unknown-usage reservations remain accounted for; the corrective allowance has 4683562 microusd remaining after calibration.
