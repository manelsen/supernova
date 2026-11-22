# Interacting with Supernova

## Configure Channels

Enable channels in `supernova.yaml` and provide tokens (prefer env vars):

- telegram
- discord
- matrix
- lark
- google_chat
- slack
- mattermost
- wechat_work
- whatsapp

## Start Runtime

```sh
gleam run
```

Or run with container stack:

```sh
docker compose up -d
```

## Common User Flows

- `/start` initializes channel conversation context.
- `/help` returns command guidance.
- `/status` returns runtime/session status.
- `/model` opens model/provider selection flow (interactive or textual fallback by channel capability).

## Operational Observability

Check logs for:

- channel bootstrap success/failure,
- inbound payload normalization,
- runtime execution and tool calls,
- outbound delivery outcomes.

## Troubleshooting Basics

- Missing config or token: validate `supernova.yaml` and environment variables.
- No responses from bot: verify channel-side bot registration and token validity.
- Runtime startup failure: inspect config validation errors.

