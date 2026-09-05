# Dialyzer warning filters. Keep empty unless a warning is a confirmed false
# positive — each entry is either a regex string or a {file, warning} tuple.
# `list_unused_filters: true` (mix.exs) flags entries here that no longer match.
[
  # ViewerFrontend.failure_code/1 reduces a tagged start failure to its tag,
  # because the code is interpolated into `viewer/<code>` and a tuple there
  # raises. Dialyzer types the capture callback from its default
  # implementation, whose refusals are all atoms, so it reports the tuple
  # clause as unreachable; "a tagged capture refusal is reported under its own
  # code" in test/ptc_runner/viewer_frontend_test.exs executes it.
  {"lib/ptc_runner/viewer_frontend.ex", :pattern_match_cov}
]
