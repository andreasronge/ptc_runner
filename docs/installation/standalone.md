# Standalone installation

Install the self-contained `ptc` executable from GitHub Releases.

A target machine does not need Elixir, Erlang, Python, Node.js, or a separately
installed sandbox to run an application that needs no API key or an agent
whose external tools are remote.

## Download the release

Open [GitHub Releases](https://github.com/andreasronge/ptc_runner/releases) and
download the macOS arm64 archive together with its adjacent `.sha256` file.
Release archives use this name:

```text
ptc-VERSION-macos-arm64.tar.gz
```

Verify the checksum before extracting the archive:

```console
shasum -a 256 -c ptc-VERSION-macos-arm64.tar.gz.sha256
tar -xzf ptc-VERSION-macos-arm64.tar.gz
./ptc/bin/ptc --version
```

Move the complete extracted `ptc` directory to a stable location and add its
`bin` directory to your `PATH`. Keep the release tree together; the launcher
uses the runtime and libraries beside it.

## Artifact contract

A packaged archive is named `ptc-VERSION-macos-arm64.tar.gz` and ships with an
adjacent SHA-256 file. It records its minimum supported macOS version in
`MINIMUM_MACOS`.

macOS archives are ad-hoc signed. They are not Developer ID signed and are not
notarized. A browser download carrying a quarantine flag may require you to
remove that flag before the first run.

After extraction, verify the executable before using credentials:

```console
ptc --version
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

External MCP servers retain their own runtime and installation requirements.
The standalone executable removes PtcRunner's toolchain requirement; it does
not silently bundle every server you may choose to connect.
