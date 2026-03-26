# Onboarding Overview

Supernova has two onboarding paths. Both configure provider auth, workspace configuration, and channel setup, but differ in interaction style.

## Which path should I use?

|                | CLI onboarding                          | Wizard module onboarding             |
| -------------- | ---------------------------------------- | ------------------------------------ |
| **Platforms**  | macOS, Linux, Windows (WSL2)             | macOS, Linux, Windows (WSL2)         |
| **Interface**  | Manual terminal steps                    | Guided terminal wizard               |
| **Best for**   | CI/servers, explicit control             | Fast local setup                     |
| **Automation** | Strong (scripts + env vars)              | Manual only                          |
| **Command**    | `cp examples/quickstart/supernova.yaml` | `gleam run -m supernova/wizard_main` |

Most users should start with **wizard onboarding** and then fine-tune `supernova.yaml`.

## What onboarding configures

1. **Provider and auth** — API key and default model in `providers`
2. **Workspace/runtime config** — environment and logging
3. **Budgets** — recursion depth, token and tool-call limits
4. **Channels** — Telegram/Discord and optional scaffolded channels
5. **MCP servers (optional)** — `mcp_servers` auto-registered at startup

## CLI onboarding

Use the quickstart config template:

```bash
cp examples/quickstart/supernova.yaml supernova.yaml
```

Then adjust providers/channels and run:

```bash
gleam run
```

## Wizard onboarding

Run:

```bash
gleam run -m supernova/wizard_main
```

The wizard helps generate `supernova.yaml` interactively.

## Notes

- Sensitive values should be provided via environment variables.
- On startup, Supernova loads `supernova.yaml`; if not found, it falls back to defaults.
- If `mcp_servers` is present, each server is registered during bootstrap through the MCP manager.

