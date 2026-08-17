# Install models and tools

> **Audience:** operators installing credentials, model routes, MCP tools, and
> outer policy independently of an application.

The host document is the authority boundary. An application may select and
narrow an installed alias, but it cannot create one or change its credentials,
endpoint, command, effects, or ceilings.

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

Install MCP tools with the same separation: the host fixes the transport and
public tool mapping, while the application selects the alias and may narrow a
write-bearing tool set. Follow [Connect an MCP tool](connecting-tools-with-mcp.md)
for one complete workflow.

The [host-configuration reference](../reference/host-installation.md) owns the
complete credential forms, provider sources, transport rules, OAuth behavior,
data classes, ceilings, and diagnostics.
