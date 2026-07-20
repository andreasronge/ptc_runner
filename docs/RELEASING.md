# Releasing `ptc_runner`

Root releases use `v*` tags and publish the single `ptc_runner` Hex package.

From a clean branch merged to `main`, update the version in `mix.exs` and add a
versioned `CHANGELOG.md` section. Run:

```bash
mix precommit
mix prepush
mix hex.build
```

Dispatch the release gate from the versioned commit on `main`. After it is
green and release approval is explicit, create and push `vX.Y.Z`. The tag
workflow re-runs the package and documentation gates; it does not publish.

Hex and HexDocs publication is a separate, explicit maintainer action performed
from the tagged `main` commit. Verify the package, documentation, changelog,
artifacts, and tag after publication.

Do not create or push a release tag, publish a package, or publish documentation
without explicit user confirmation.
