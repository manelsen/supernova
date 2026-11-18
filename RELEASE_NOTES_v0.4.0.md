# Release Notes — Supernova 0.4.0

## Highlights

Supernova 0.4.0 turns the runtime into a **closed group**: access is denied by
default, every person has an hourly budget enforced by the kernel, every tool
call passes through the syscall gateway, and Telegram/Discord are covered by
mocked end-to-end tests. The other seven channels are experimental.

## What's Changed

### Access and identity

- Added `core/principal.gleam`: the speaking person is identified as
  `<channel>:<user_id>` independently of the conversation session.
- Added deny-by-default allowlists (`access.admins`, `access.members`,
  `SUPERNOVA_ACCESS_ADMINS` / `SUPERNOVA_ACCESS_MEMBERS`), persisted runtime
  changes in `<data_dir>/access.json`, and `/acesso` admin commands.
- Denied people receive at most one reply per 24 h; admin commands are only
  available to admins.
- Group chats and Discord guilds require an explicit `access.allowed_chats`
  entry. Telegram leaves unauthorized groups when added.
- Added a per-principal sliding-window message limit (`rate_limit`).

### Kernel wiring

- `budget_policy` is started under supervision and enforces hourly tokens and
  tool calls per principal; admins can be unlimited with `-1`.
- Instance-wide daily USD cap with model pricing (`pricing`,
  `instance_budget`), cost estimates in the ledger, and admin
  `/teto liberar <usd>`.
- Every tool call now goes through `SyscallGateway.invoke_tool/5`
  (capability → workspace → budget → execution → ledger → audit). Role-based
  capability manifests hide denied tools from the LLM.
- Added fail-closed behavior and explicit two-second timeouts for access,
  budget, ledger and audit calls.

### Observability and operations

- Per-principal usage ledger in `<data_dir>/ledger/*.jsonl`, 30-day rotation,
  `/uso` and `/uso todos`.
- Admin `/auditoria [n]` and `/auditoria <principal>` queries; no user message
  content is stored.
- Admin alerts for 80% budget, instance cap 80%/100%, abuse (>5 denials in
  10 min) and fail-closed events, deduplicated for one hour.
- `config_check` and `bin/supernova check-config` validate access, budgets,
  capabilities, rate limits, instance cap and channel support at boot.
- Experimental channels warn at boot.
- Container images are published only on `v*` tags.

### Hardening after the closed-group review (B1.1)

- Access lists persist only deltas over YAML (`added`/`removed`), and legacy
  `access.json` files are migrated on load.
- The daily cost total is maintained per day inside the ledger actor; LLM
  admission reserves the estimated cost first, and actual usage replaces the
  reservation using an idempotent call id.
- Split replies treat "message is not modified" as success, retry rate-limited
  parts, and send a final fallback instead of leaving a half-delivered answer.
- The bot records a group leave only after Telegram confirms it, and rechecks
  access before each leave retry.
- Non-member interactions are denied before touching a shared picker.
- Chat lanes drain before channel dependencies stop; tool calls are charged
  when claimed, and unclaimed or cancelled claims are refunded.

## Upgrade Notes

- Set at least one admin before starting:
  `SUPERNOVA_ACCESS_ADMINS="telegram:123"` or `access.admins` in YAML.
- A new instance answers nobody until configured; `/eu` is the only command
  available to unauthenticated people.
- Set `instance_budget.daily_usd` explicitly (`-1` disables the cap and logs a
  warning).
- Run `bin/supernova check-config supernova.yaml` after editing configuration.

## Known limitations

- Discord admin alerts open a DM channel through the Discord API; the bot must
  share a guild with the admin.
- The shared `blackboard` and `memory_federation` remain intentionally
  unwired; an architecture test prevents wiring them before PRD B3.
