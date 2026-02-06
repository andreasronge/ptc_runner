Run the full precommit check suite and fix all issues:
1. Run `mix compile --warnings-as-errors` and fix any warnings
2. Run `mix credo --strict` and fix all issues
3. Run `mix dialyzer` and fix all warnings
4. Run `mix test` and ensure all pass
5. Stage and commit only when ALL checks pass
6. Then push and verify the pre-push hook passes
