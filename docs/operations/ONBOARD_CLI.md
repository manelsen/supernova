# `supernova onboard` (equivalent CLI onboarding flow)

Supernova does not yet expose a single `supernova onboard` command.  
The equivalent CLI onboarding flow is:

```bash
cp examples/quickstart/supernova.yaml supernova.yaml
gleam run -m supernova/wizard_main   # optional guided setup
gleam run
```

## Examples

Manual quickstart:

```bash
cp examples/quickstart/supernova.yaml supernova.yaml
gleam run
```

Guided wizard:

```bash
gleam run -m supernova/wizard_main
gleam run
```

With MCP servers:

```yaml
mcp_servers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem"]
```

Then:

```bash
gleam run
```

## Notes

- `supernova.yaml` is optional; defaults are applied if absent.
- Secrets should be supplied via environment variables.
- `mcp_servers` entries are auto-registered at startup.

