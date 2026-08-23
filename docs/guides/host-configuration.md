# Install models and tools

Use `ptc-host.json` to install credentials, model routes, MCP tools, and outer
limits separately from an application.

`ptc.json` may select an installed alias
and ask for less, but it cannot create one or change its credentials, endpoint,
command, effects, or ceilings.

## How do I install a model?

Install one model alias with a credential read from the process environment:

```json
{
  "credentials": {
    "model_key": {"env": "OPENROUTER_API_KEY"}
  },
  "install": {
    "model": {
      "source": "llm",
      "installation_revision": "model-v1",
      "model": "openrouter:deepseek/deepseek-v4-flash",
      "credential": "model_key",
      "cache": false,
      "params": {"max_tokens": 4096}
    }
  }
}
```

Keep its path in `ptc-project.json`, then verify the selected application:

```console
ptc doctor ptc-project.json
ptc doctor ptc-project.json --connect
ptc models ptc-project.json
```

Plain `doctor` validates configuration without loading credentials or dialing
providers. `--connect` is an explicit connectivity probe and may consume remote
resources.

## How do I install an MCP server?

Install MCP tools with the same separation: the host fixes the transport and
public tool mapping, while the application selects the alias and may narrow a
write-bearing tool set. The `workspace` alias selected in
[Configure an application](manifests-and-capabilities.md) is installed as a
second entry under the same `install` object:

```json
{
  "workspace": {
    "source": "mcp",
    "installation_revision": "workspace-v1",
    "transport": {
      "type": "stdio",
      "command": "node",
      "args": ["server.js"]
    },
    "tools": {
      "read_text_file": {"as": "workspace.read", "effect": "read"}
    },
    "ceilings": {"timeout_ms": 15000, "max_result_bytes": 262144}
  }
}
```

The upstream operation name and server command belong to the server you run.
You choose the public `as` name and its `read` or `write` effect. Follow
[Connect an MCP tool](connecting-tools-with-mcp.md) for one complete workflow
against a checked-in server.

`ptc validate` reports `installation_config_digests` for the selected aliases so
you can compare the host declaration you reviewed with the one a later
validation or run actually named. The digest is configuration identity, not
proof of live server scope; see the
[host-configuration reference](../reference/host-installation.md).

## Where is the complete contract?

The [host-configuration reference](../reference/host-installation.md) owns the
complete credential forms, provider sources, transport rules, OAuth behavior,
data classes, ceilings, and diagnostics.
