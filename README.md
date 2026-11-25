# Supernova

**An operating system for AI agents, built on the BEAM, and home to companion agents that each belong to one person.**

---

## What is this?

Supernova runs a group of people, each with an agent of their own. An agent:

- **is born with a character.** It is sampled from a constellation of traits and written as a core that is the agent's alone. The person gives it a name.
- **remembers and changes slowly.** It keeps a journal and reflects on it. Repeated experience can add to its core over time.
- **forgets on request.** `/esquecer` erases everything the person told it, and keeps who it became.
- **keeps an agenda.** It can do things later, or every day at a given hour.
- **opens what the person sends.** On WhatsApp it hears voice notes, watches videos, reads documents and describes images and stickers, and can answer with its voice. Built for people with disabilities first, on what [Amélie](https://github.com/manelsen/amelie) learned.
- **can have a computer of its own.** A Linux machine with a shell and a browser it sees through screenshots, isolated by gVisor, holding no secrets.
- **talks to the person on Telegram, WhatsApp and Discord**, as the same agent on all of them when the person links them (`/vincular`). Other channels can only send for now (see Channels).

Underneath is an operating system. Agents live in userland and ask a kernel for everything: files, tools, model calls. The kernel checks ownership, quota and permission, charges the cost and writes it down. The instance is a closed group: nobody gets in without being on the access list, and every person and the whole instance have spending ceilings.

---

## Why does this need an OS?

An agent is a loop: the model decides, calls a tool, reads the result, decides again. Put that loop in front of real people and four things go wrong:

1. **Budget burns silently.** One person finds a way to make the loop run ten thousand times, and the bill arrives at the end of the month.
2. **Agents can do anything.** Something the agent reads says "ignore your instructions", and the agent touches what it should not.
3. **People bleed into each other.** One agent sees another person's files or messages.
4. **Nobody gets their turn.** One long task starves everyone else.

Supernova handles these as kernel primitives, not library features:

```
┌──────────────────────────────────────────────────────────┐
│ USERLAND    agent of person A   agent of person B   ...  │
└────────────────────────────┬─────────────────────────────┘
                             │ syscall
┌────────────────────────────▼─────────────────────────────┐
│ KERNEL                                                   │
│   Closed group: access → rate limit → admission → lane   │
│   SyscallGateway                                         │
│     ├── WorkspacePolicy     (does this agent own this?)  │
│     ├── BudgetPolicy        (is there quota left?)       │
│     ├── CapabilityManifest  (is this tool allowed?)      │
│     ├── ResourceLedger      (charge the operation)       │
│     └── AuditLog            (record what happened)       │
│   KernelScheduler           (fair round-robin)           │
└──────────────────────────────────────────────────────────┘
```

The kernel runs on the BEAM, the Erlang VM. Every agent, session and lane is a supervised actor: when one crashes, it restarts on its own and the others keep going.

The rule behind the design: **whoever enforces the rules must be out of reach of whoever follows them.** That is why keys and people's data never enter the agent's computer, and why every tool call goes through the kernel.

More in [docs/architecture/ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md).

---

## Channels

| Channel | Status |
|---|---|
| **Telegram** | Supported: receives and sends; closed group, commands, buttons, streaming |
| **WhatsApp** | Supported through the GOWA bridge: receives and sends, private chats only (groups off for now); closed group; reads every medium the person sends (voice notes, video, documents, images, stickers) and can answer with voice (`/voz`); one agent across channels with `/vincular`. See [docs/operations/WHATSAPP.md](docs/operations/WHATSAPP.md) |
| **sim** | Local HTTP channel used by the test harness |
| **Discord** | Supported: receives and sends through the gateway; private chats and authorized servers; closed group, slash commands with suggestions, buttons, streaming; reads every medium the person sends (voice messages, images, video, documents, stickers); one agent across channels with `/vincular`. Not yet tried with a real bot (see [docs/operations/DISCORD.md](docs/operations/DISCORD.md)) |
| Slack, Matrix, Lark, Google Chat, Mattermost, WeChat Work | Send only, experimental: the adapters can deliver messages but do not receive them yet, and are not behind the closed group |

## Providers

OpenAI, Anthropic, OpenRouter, OpenCode Zen, Zhipu, Zhipu Coding, Z.ai, Z.ai Coding, MiniMax, Mistral (which also serves DeepSeek), and Ollama for local models. The pilot runs on DeepSeek V4.1 Flash, through Mistral. Calls go through a circuit breaker, a failover cooldown and retry with backoff. `/model` switches the model with buttons.

## Tools

The agent decides when to use them. Each role has its own allowlist: members are denied the riskier tools by default.

| Tool | What it does |
|---|---|
| `file_system` | The person's workspace |
| `agenda` | Do something later, or on a schedule |
| `web`, `browser` | Fetch pages; drive a headless browser |
| `github`, `git_inspect` | Read repositories |
| `safe_shell` | Restricted commands on the host |
| `process` | List, inspect and stop processes |
| `canvas` | Structured blocks |
| `computador` | The agent's own computer (optional, gVisor) |

MCP servers can add more tools.

---

## Quickstart

```sh
git clone https://github.com/manelsen/supernova && cd supernova
cp supernova.yaml.example supernova.yaml   # keep only your provider; under telegram:, set enabled: true
cp .env.example .env && chmod 600 .env    # provider key, bot token
docker compose up -d --build
```

Agents use the provider whose name sorts first in `supernova.yaml`, so remove the providers you do not use; Supernova refuses to start if that provider has no key. Then send `/eu` to your bot, put your id in `SUPERNOVA_ACCESS_ADMINS`, and restart. The step-by-step version is in [GETTING_STARTED.md](GETTING_STARTED.md). Running a group is covered in [DEPLOY.md](DEPLOY.md). A wizard that does all of this for you is planned.

## Development

Toolchain versions are pinned in [`.tool-versions`](.tool-versions): Erlang 28.5.0.8, Gleam 1.19.2.

```sh
make test                         # the whole offline suite
make test-only T="dir@module_test"
make coverage                     # instrumented run, 79% minimum
gleam format --check src test
gleam build --warnings-as-errors
```

Tests never call a real model. Working rules for contributors and coding agents are in [AGENTS.md](AGENTS.md) and [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

---

## Status

Version **0.4.0**, running as a pilot instance. Current numbers are in [docs/STATUS.md](docs/STATUS.md). Everything still open, with the decisions already taken and their priority, is in [docs/PENDENCIAS.md](docs/PENDENCIAS.md).

## Documentation

| Where | What |
|---|---|
| [GETTING_STARTED.md](GETTING_STARTED.md), [DEPLOY.md](DEPLOY.md) | Running it |
| [docs/operations/](docs/operations/) | Docker, the agent's computer, observability, interaction |
| [docs/architecture/](docs/architecture/) | How it is built |
| [docs/HARNESS.md](docs/HARNESS.md) | Personas and judge: behavioral tests with simulated people |
| [docs/prd/](docs/prd/), [docs/relatorios/](docs/relatorios/) | What was planned in each phase, and what was delivered |
| [docs/releases/](docs/releases/) | Release notes |
| [docs/PENDENCIAS.md](docs/PENDENCIAS.md) | What is open, and in what order |
| [docs/arquivo/](docs/arquivo/) | Old plans, kept as history |

## Why Gleam and the BEAM?

- **Supervisors:** crash recovery is part of the runtime, not a library.
- **Message passing:** concurrency is the default.
- **Static types:** whole classes of bugs never reach a person.
- **The BEAM:** a VM designed for systems that must not go down.

## License

MIT.
