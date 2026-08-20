Run the local quality gate, then push once:

1. Run `mix precommit` (nested fetch + `scripts/ci/core-quality.sh`) and fix every failure.
2. Stage and commit. The git pre-commit hook is the fast staged-file path; it is not a substitute for `mix precommit`.
3. Push with `git push` and let the tracked pre-push hook run the CI-equivalent gate (docs, tests, Dialyzer, release, Viewer). Do not follow `mix precommit` with `git push --no-verify`: pre-push still adds Dialyzer and ExDoc. Do not run `mix prepush` immediately before a normal `git push`.

`mix precommit` does not run the suite, Viewer, launcher, Dialyzer, ExDoc, or release.
