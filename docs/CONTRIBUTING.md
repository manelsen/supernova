# Contributing to Supernova

Thanks for contributing.

## Prerequisites

- Gleam >= 1.0
- Erlang/OTP >= 25

## Development Setup

1. Clone repository.
2. Download deps:

```sh
gleam deps download
```

3. Create/update `supernova.yaml` (or run wizard):

```sh
gleam run -m supernova/wizard_main
```

## Quality Gates

Run before opening a PR:

```sh
gleam format --check src test
gleam test
```

## Coding Guidelines

- Keep adapter logic at Port boundaries; avoid leaking channel-specific payloads into core.
- Prefer pure modules for business rules and actor modules for orchestration/lifecycle.
- Add documentation for all public functions (`///` style doc comments).
- Add tests for any behavior change (unit + integration when applicable).

## Commit Style

Use focused, atomic commits grouped by logical change.

Examples:

- `feat: add channel port contract and shared routers`
- `chore: remove unused runtime imports`
- `docs: add architecture and operations guides`

## Pull Request Checklist

- [ ] Scope is focused and coherent.
- [ ] Tests added/updated and green.
- [ ] `gleam format --check src test` passes.
- [ ] Public APIs are documented.
- [ ] README/docs updated if behavior changed.

