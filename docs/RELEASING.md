# Releasing `ptc_runner`

Root releases use `v*` tags and publish the single `ptc_runner` Hex package.

From a clean branch merged to `main`, update the version in `mix.exs` and add a
versioned `CHANGELOG.md` section. Run:

```bash
mix precommit
mix prepush
mix hex.build
```

After the release workflow is green, create and push `vX.Y.Z`. The tag workflow
re-runs the package gates and publishes Hex and HexDocs using `HEX_API_KEY`.
Verify the published package, documentation, changelog, and tag afterwards.

Do not create or push a release tag without explicit user confirmation.
