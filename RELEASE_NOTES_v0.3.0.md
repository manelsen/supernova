# Release Notes — Supernova 0.3.0

## Highlights

Supernova 0.3.0 stabilizes and hardens the codebase after the v0.2.0 multi-channel milestone: zero compiler warnings under `--warnings-as-errors`, `1998` passing tests, `74.49%` line coverage enforced in CI (`>= 73%` threshold), isolated test workspaces, reconciled audit findings, updated toolchain (`Erlang 28.5.0.8` / `Gleam 1.19.2`) and `gleam_stdlib 1.x` / `hackney 4.x` dependencies, plus a verified Docker boot smoke test.

---

## What's Changed

### Quality, Tooling & CI

- **Coverage & test suite consolidation** — integrated coverage instrumentation (`scripts/coverage/line_coverage.escript` via `make coverage`, threshold `73%`), reaching `74.49%` line coverage (`8929/11987` lines) across `1998` tests
- **Test workspace isolation** — added `SUPERNOVA_WORKSPACE_ROOT` support in `channel_common_router.gleam` and temporary directory cleanup in tests so `gleam test` leaves no artifacts under `workspaces/`
- **Pinned toolchain** — added `.tool-versions` (`erlang 28.5.0.8`, `gleam 1.19.2`) and aligned `Dockerfile` (`erlang:28.5.0.8-alpine`, `GLEAM_VERSION=1.19.2`)
- **Zero compiler warnings** — removed dead streaming helpers and unreachable clauses, replaced direct `yay.parse_file` usage in `config.gleam` with `supernova_file_system_ffi:read_file/1`, and enabled `gleam build --warnings-as-errors` in CI
- **Restored GitHub Actions CI** — added `.github/workflows/test.yml` checking formatting, `--warnings-as-errors`, `gleam test`, `make coverage`, and clean working tree; updated `.github/workflows/docker.yml` branch triggers to `master`

### Security & Audit Hardening

- **Audit reconciliation (`audit/STATUS_2026-11.md`)** — mapped all `16` audit findings and `9` requirements (`20 RESOLVIDO`, `5 ACEITO` deferred to live validation in PRD B)
- **Browser `evaluate` disabled by default** — added `tools.browser.allow_evaluate` (default `False`, env override `SUPERNOVA_BROWSER_TESTS` / `SUPERNOVA_BROWSER_ALLOW_EVALUATE`); both `evaluate` and `execute` reject arbitrary JS unless explicitly enabled
- **Path & shell containment** — verified absolute-path rejection in `file_system`, added SSRF guards and tests in `web` and `browser`, replaced prefix checks in `safe_shell` with `workspace_guard.validate_path`, and enforced `workspace_policy` inside `tools/gateway.gleam`
- **Opt-in live browser tests** — gated real-Chromium tests behind `SUPERNOVA_BROWSER_TESTS=1` while keeping decoder and policy tests always active
- **Runtime lifecycle tests** — added tests covering Slack/Matrix handler dispatch, POSIX signal graceful shutdown, infrastructure supervisor child restart, and real health/readiness endpoint JSON

### Dependencies & Container Smoke Test

- **Dependency updates** — updated `gleam_stdlib` to `1.1.0`, `gleam_otp` to `1.3.0`, `gleam_http` to `4.5.0`, `gleam_hackney` to `1.4.0`, and `hackney` to `4.12.1`; updated `supernova_llm_stream_ffi.erl` to handle both `pid()` and `reference()` async stream handles in hackney 4.x
- **Docker smoke test** — added offline-safe fixture [test/fixtures/docker/supernova.yaml](test/fixtures/docker/supernova.yaml) and documented container `/health/live` verification in `DEPLOY.md`

---

## Upgrade Notes

- `tools.browser.allow_evaluate` now defaults to `false`. Deployments requiring browser JavaScript evaluation must explicitly enable it in `supernova.yaml` or via `SUPERNOVA_BROWSER_ALLOW_EVALUATE=true` (recommended only in isolated sandboxes).
- Use `SUPERNOVA_BROWSER_TESTS=1` when running real Chromium Playwright tests locally.
- Local and CI builds now expect `erlang 28.5.0.8` and `gleam 1.19.2` (see `.tool-versions`).

---

## Validation

```bash
gleam format --check src test          # ✓ clean
gleam build --warnings-as-errors       # ✓ 0 warnings
gleam test                             # ✓ 1998 passed, 0 failures
make coverage                          # ✓ 74.49% >= 73.00% threshold
```
