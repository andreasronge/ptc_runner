# Releasing `ptc_runner`

> **Audience:** maintainers publishing the source package and standalone
> releases.

Root releases use `v*` tags and publish the single `ptc_runner` Hex package.

## Release checklist

1. On a clean `main`, update `mix.exs` and add a versioned `CHANGELOG.md`
   section dated for the expected publication day. Run `mix regen`; if it
   changes the semantic projection, commit and push it before continuing.
2. Run the local preparation checks:

   ```bash
   mix precommit
   FORCE_FULL_PRE_PUSH=1 .githooks/pre-push
   MIX_ENV=prod mix hex.build
   ```

3. Record `git rev-parse HEAD`, dispatch `Release Gate` from `main`, and confirm
   that exact commit passes verification, macOS packaging, and both container
   targets. Local checks do not replace this gate. Any fix creates a new
   candidate and requires a fresh dispatch.
4. After the gate is green and release approval is explicit, create and push
   `vX.Y.Z` at the verified commit.

The tag run repeats the gates and packages the standalone macOS arm64 artifact
with `scripts/package_standalone_release.sh`, which closes the release's runtime
library set, re-signs what it rewrote, and verifies the packaged tree with
`scripts/verify_standalone_release.sh`. It records build provenance for the
artifact and attaches it, with its `.sha256`, to a draft GitHub release. That
release stays a draft until a maintainer publishes it, exactly as the launcher
release does. It does not publish to Hex.

After the canonical verification job passes, the root release workflow calls
`.github/workflows/container-release.yml`. That reusable workflow builds and
drives the finished image on native Linux AMD64 and ARM64 runners. For a root
`vX.Y.Z` tag, each runner pushes its tested image by digest. The workflow
assembles those exact digests into one multi-platform manifest, attests and
verifies it, and only then creates the exact version tag under
`ghcr.io/andreasronge/ptc_runner`. It adds signed GitHub build provenance for
the manifest digest. A direct manual dispatch runs both native verification
jobs without logging in or publishing.

Only three-part release versions are accepted, and the only supported image
tag is the exact version. The workflow treats that tag as non-moving, refuses
to replace one, and creates no moving aliases. GHCR does not enforce this as
registry-level tag immutability, so deployments should pin the repository digest
and verify its attestation. Run-scoped `staging-*` references are publication
internals, not release names, and consumers must not use them. The first package
publication under the repository owner defaults to private in GHCR; before
publishing the GitHub release, change that package to public once and confirm
an unauthenticated pull. Public visibility cannot later be reversed.

After the container workflow is green, verify the signed subject from an
authenticated GitHub CLI and GHCR session:

```bash
release_tag=vX.Y.Z
image="ghcr.io/andreasronge/ptc_runner:${release_tag#v}"
gh attestation verify "oci://$image" \
  --repo andreasronge/ptc_runner \
  --signer-workflow \
    andreasronge/ptc_runner/.github/workflows/container-release.yml \
  --source-ref "refs/tags/$release_tag" \
  --deny-self-hosted-runners
```

The assembled release and the container image carry the `ptc_viewer`
companion, so the packaged `ptc viewer` command works from an extracted tarball
with no toolchain beside it. The Hex package does not: `ptc_viewer` is
unpublished, and `mix.exs` therefore names it only when the sibling checkout
exists and the invocation is a development, test, or `release` one.
`scripts/verify_core_package.sh` asserts both halves — the built package
carries no `ptc_viewer` requirement and no `ptc_viewer` sources, and its
sources still compile at `prod` with the companion absent. Do not turn that
into an optional Hex requirement without publishing the package first; Hex
cannot resolve a requirement naming a package that does not exist.

The macOS artifacts are ad-hoc signed — not Developer ID signed, not notarized —
and the installation documentation must say so in those words. macOS arm64 is
the only standalone target; the published Linux container covers AMD64 and
ARM64. macOS x86_64 still requires its own target evidence, and publishing it
without that evidence is out of contract.

Hex and HexDocs publication is a separate, explicit maintainer action. Dispatch
`Publish PtcRunner to Hex` with the published root tag. Its protected
`hex-publish` environment should require maintainer approval and provide a
`HEX_API_KEY` secret with only the required Hex API write authority. The
workflow checks out the requested tag, requires its immutable GitHub release
and ancestry from `main`, builds the package with the production dependency
set, and builds HexDocs with the development dependency set where `ex_doc` is
installed. After maintainer approval, the protected publish job starts on a
separate fresh runner, downloads and verifies those artifacts, and exposes the
Hex credential only to the upload step. The credential is never available to
dependency installation, compilation, documentation generation, or any process
retained from them. A rerun skips an existing package only when its Hex
checksum matches the package rebuilt from the tag; it still republishes
documentation. Verify the package, documentation, changelog, artifacts, and
tag after publication.

Do not create or push a release tag, publish a package, or publish documentation
without explicit user confirmation.

## Releasing `ptc_runner_launcher`

The optional launcher companion has an independent version in
`ptc_runner_launcher/release_config.exs` and uses
`ptc_runner_launcher-vX.Y.Z` tags. From a clean commit on `main`, run the root
`mix precommit` quality gate and `FORCE_FULL_PRE_PUSH=1 .githooks/pre-push`.
After release approval is explicit,
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
