# Standalone installation

> **Audience:** operators installing the self-contained `ptc` executable on a
> supported machine.

The standalone release contains its runtime. A target machine does not need
Elixir, Erlang, Python, Node.js, or a separately installed sandbox to run a
provider-free application or an agent whose external tools are remote.

## Current availability

The repository builds and verifies a relocatable macOS arm64 archive, but the
current public release predates that packaging path and does not contain the
archive. A one-command installer must not be advertised until a published
release carries the verified asset and adjacent checksum.

For now, build the archive from a source checkout as described in
[Source installation](source.md), or use the local [Docker image](docker.md).
A one-command installer will become the default only after a public release
contains the verified asset it downloads.

## Artifact contract

A packaged archive is named `ptc-VERSION-macos-ARCH.tar.gz` and ships with an
adjacent SHA-256 file. It records its minimum supported macOS version in
`MINIMUM_MACOS`.

macOS archives are ad-hoc signed. They are not Developer ID signed and are not
notarized. Verify the adjacent checksum before extracting an archive. A browser
download carrying a quarantine flag may require the operator to remove that
flag before the first run.

After extraction, verify the executable before using credentials:

```console
ptc --version
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

External MCP servers retain their own runtime and installation requirements.
The standalone executable removes PtcRunner's toolchain requirement; it does
not silently bundle every server an operator may choose to grant.
