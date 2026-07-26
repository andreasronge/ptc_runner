# Releasing `ptc_runner`

Root releases use `v*` tags and publish the single `ptc_runner` Hex package.

From a clean branch merged to `main`, update the version in `mix.exs` and add a
versioned `CHANGELOG.md` section. Run:

```bash
mix precommit
mix prepush
MIX_ENV=prod mix hex.build
```

Dispatch the release gate from the versioned commit on `main`. After it is
green and release approval is explicit, create and push `vX.Y.Z`. The tag
workflow re-runs the package and documentation gates; it does not publish.

Hex and HexDocs publication is a separate, explicit maintainer action performed
from the tagged `main` commit. Publish the package with
`MIX_ENV=prod mix hex.publish package` so it uses the same optional Hex
dependency metadata as the verified archive instead of the local development
path. Publish documentation separately with
`MIX_ENV=dev mix hex.publish docs`, where `ex_doc` is installed. Verify the
package, documentation, changelog, artifacts, and tag after publication.

Do not create or push a release tag, publish a package, or publish documentation
without explicit user confirmation.

## Releasing `ptc_runner_launcher`

The optional launcher companion has an independent version in
`ptc_runner_launcher/release_config.exs` and uses
`ptc_runner_launcher-vX.Y.Z` tags. From a clean commit on `main`, run the root
`mix precommit` and `mix prepush` gates. After release approval is explicit,
create and push the matching companion tag.

The launcher tag workflow first proves that the tagged commit is on `main` and
passes the root release gates. It then builds and executes the configured
artifacts on the pinned macOS 15 ARM64 and x86-64, Ubuntu 22.04 x86-64, and
Ubuntu 24.04 ARM64 baselines, exercises download and mandatory SHA-256
verification, proves source fallback, and creates a draft GitHub release
containing:

- each precompiled port archive and its adjacent `.sha256` file;
- the complete `checksum.exs`; and
- the verified `ptc_runner_launcher-X.Y.Z.tar` Hex package containing that
  checksum map and the source fallback.

Before creating the draft, the tag workflow records GitHub Actions build
provenance for every asset. This binds each asset digest to the trusted release
workflow, tag ref, and tagged commit even while the draft remains editable.

Enable GitHub release immutability for the repository before publishing that
draft. Publication locks the tag and assets and creates their attestations.
After publication, require both `isImmutable: true` and successful
`gh release verify TAG` before treating the release as complete. The protected
Hex workflow enforces those checks again, verifies the downloaded package
asset, and requires its build-provenance signer, source tag, and source commit
to match the tag workflow.

Hex publication remains a separate, explicit maintainer action. Dispatch
`Publish PtcRunner Launcher to Hex` with the published companion tag. Its
`hex-publish` environment should require maintainer approval and provide a
`HEX_API_KEY` secret with only the required Hex API write authority. The
workflow downloads the attached verified package and uploads those exact bytes
to Hex after verifying both the release attestation and the tag workflow's
build-provenance attestation; it does not rebuild the package. Scope the Hex key
only to that protected publication environment.

Do not run `mix hex.publish` for the companion. That command creates a new
tarball and would bypass the release workflow's verified archive and checksum
map.
