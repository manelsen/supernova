## US-001 - Ligar bootstrap de canais no main
- Branch: us/us-001-ligar-bootstrap-de-canais-no-main
- Status: complete
- Files: src/supernova.gleam, src/supernova/channel/registry.gleam, test/channel/registry_test.gleam, docker-compose.yml, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: updated `test/channel/registry_test.gleam` with regressions proving registry bootstrap routes injected Discord gateway message events and Telegram updates into the shared inbound handler
- Validation: `gleam test` passed; `gleam build` passed; `gleam format src/supernova.gleam src/supernova/channel/registry.gleam test/channel/registry_test.gleam` passed; `gleam format --check src test` passed after formatting the previously dirty preexisting files; `docker compose up -d postgres` passed after a temporary host port remap to `127.0.0.1:5433`
- Risks: Discord gateway transport is still using the existing stubbed `connect_to_gateway`, so the live websocket transport itself remains shallow even though bootstrap now wires inbound events to the shared router boundary
- Carry forward: `US-001` now unblocks dependency flow for `US-002`; remaining gaps are broader adapter richness, not channel startup/shutdown wiring

## US-002 - Conectar Port Adapter de ponta a ponta
- Branch: us/us-002-conectar-port-adapter-de-ponta-a-ponta
- Status: complete
- Files: src/supernova/channel/port.gleam, src/supernova/channel/registry.gleam, src/supernova/adapters/google_chat_adapter.gleam, src/supernova/adapters/matrix_adapter.gleam, src/supernova/adapters/mattermost_adapter.gleam, src/supernova/adapters/slack_adapter.gleam, src/supernova/adapters/whatsapp_adapter.gleam, test/channel/registry_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: updated `test/channel/registry_test.gleam` with a regression proving the registry now exposes real `port.ChannelAdapter` values for started Discord and Telegram channels
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: none beyond the existing channel-specific runtime depth already noted in `US-001`
- Carry forward: `US-002` now unlocks the native-channel stories that depend on the Port adapter contract (`US-003` through `US-008` and other `dependsOn: ["US-002"]` backlog items)

## US-003 - Criar Matrix adapter nativo
- Branch: us/us-003-criar-matrix-adapter-nativo
- Status: complete
- Files: src/supernova/adapters/matrix_adapter.gleam, test/adapters/matrix_adapter_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: expanded `matrix_adapter_test` with regressions for edited Matrix events, redaction filtering, HTML-formatted outbound payloads, and Matrix edit payload generation via `m.replace` + `m.new_content`
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: outbound hard delete still has no explicit cross-channel field in `ChannelReply`, so the Matrix slice currently covers delete semantics through redaction-aware inbound handling rather than a generic outbound delete contract
- Carry forward: `US-004` can assume the Port already carries rich reply metadata and that Matrix no longer blocks the native-adapter tranche

## US-016 - Evoluir ChannelReply para payload rico
- Branch: us/us-016-evoluir-channelreply-para-payload-rico
- Status: complete
- Files: src/supernova/channel/port.gleam, src/supernova/channel/registry.gleam, src/supernova/adapters/discord_rest.gleam, src/supernova/adapters/telegram.gleam, src/supernova/adapters/slack_adapter.gleam, src/supernova/adapters/channel_common_router.gleam, test/adapters/channel_port_test.gleam, test/adapters/discord_rest_test.gleam, test/adapters/telegram_test.gleam, test/adapters/slack_adapter_test.gleam, test/adapters/lark_adapter_test.gleam, test/adapters/whatsapp_adapter_test.gleam, test/adapters/matrix_adapter_test.gleam, test/adapters/mattermost_adapter_test.gleam, test/adapters/google_chat_adapter_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: expanded `channel_port_test` for media + UX metadata, added Discord REST component encoding coverage, added Telegram inline keyboard coverage, and added a Slack regression proving blocks are emitted as native JSON objects
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: media is represented in the Port contract but outbound media delivery is still adapter-specific and not yet implemented for every channel
- Carry forward: `US-020` can now add real `thread_id` semantics on top of a Port contract that already carries the field, and `US-003` no longer needs to invent richer reply metadata ad hoc

## US-020 - Threading/reply-to real em todos adapters
- Branch: us/us-020-adicionar-thread-id-a-channelreply
- Status: complete
- Files: src/supernova/adapters/matrix_adapter.gleam, src/supernova/adapters/telegram.gleam, src/supernova/channel/registry.gleam, test/adapters/matrix_adapter_test.gleam, test/adapters/telegram_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: added a Matrix regression proving `thread_id` takes precedence over `reply_to_id`, plus Telegram send-option/body coverage for `message_thread_id`
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed after `gleam clean` cleared one transient corrupted BEAM test artifact
- Risks: explicit `thread_id` semantics are now wired for Matrix and Telegram, but other non-acceptance adapters outside the story still mostly rely on legacy `reply_to_id`
- Carry forward: `US-003` can now consume a Port contract that already carries both richer payload metadata (`US-016`) and explicit thread targeting semantics (`US-020`)

## US-004 - Criar Slack adapter nativo
- Branch: us/us-004-criar-slack-adapter-nativo
- Status: complete
- Files: src/supernova/adapters/slack_adapter.gleam, src/supernova/adapters/slack_router.gleam, test/adapters/slack_adapter_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: expanded `slack_adapter_test` with regressions for real `event_callback` envelopes, bot-message subtype filtering, and `action_id` emission on Slack `static_select` blocks
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: Slack inbound interaction callbacks still are not normalized into `ChannelInteractionMessage`; this story closes outbound Block Kit rendering and inbound message normalization, not callback execution
- Carry forward: `US-005` is now the next native-adapter slice, and the shared router path has already proven enough for another channel without reopening Port-contract work

## US-005 - Criar WhatsApp adapter nativo
- Branch: us/us-005-criar-whatsapp-adapter-nativo
- Status: complete
- Files: src/supernova/adapters/whatsapp_adapter.gleam, src/supernova/channel/registry.gleam, src/supernova/config.gleam, src/supernova/wizard.gleam, test/adapters/whatsapp_adapter_test.gleam, test/channel/registry_test.gleam, test/config/config_test.gleam, test/wizard/wizard_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: rewrote `whatsapp_adapter_test` around the official bridge webhook + send-plan contract, added config/env override coverage for `bridge_url` + `device_id`, added wizard YAML coverage for the new WhatsApp fields, and added a registry regression proving the bridge adapter is really registered when enabled
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: outbound documents currently require the adapter to download the remote URL and re-upload it as multipart because the chosen bridge OpenAPI has `/send/file` but no `file_url`; that works for this story but keeps document delivery bridge-specific
- Carry forward: the explicit product decision is now `whatsmeow bridge`, not Cloud API; `US-006` can reuse the same pattern of “native parser + real outbound adapter + registry/config wiring” for the remaining channels

## US-006 - Criar adapters restantes (Google Chat, Lark, Mattermost, WeChat Work)
- Branch: us/us-006-criar-adapters-restantes-google-chat-lark-mattermost-wechat-work
- Status: complete
- Files: src/supernova/adapters/google_chat_adapter.gleam, src/supernova/adapters/lark_adapter.gleam, src/supernova/adapters/mattermost_adapter.gleam, src/supernova/adapters/wechat_work_adapter.gleam, src/supernova/adapters/wechat_work_router.gleam, src/supernova/channel/registry.gleam, src/supernova/config.gleam, src/supernova/wizard.gleam, test/adapters/google_chat_adapter_test.gleam, test/adapters/lark_adapter_test.gleam, test/adapters/mattermost_adapter_test.gleam, test/adapters/wechat_work_adapter_test.gleam, test/channel/registry_test.gleam, test/config/config_test.gleam, test/wizard/wizard_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: tightened Google Chat payload expectations, added Lark and Mattermost startup regressions, created `wechat_work_adapter_test.gleam`, added registry coverage for the four remaining adapters, and expanded config/env/wizard coverage for the new runtime fields
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: WeChat Work inbound parsing currently assumes a post-decryption JSON payload at the adapter boundary; the cryptographic callback verification/decryption step is still outside this story’s slice
- Carry forward: `US-007` can now assume the backlog’s remaining channels all have real adapter bootstrap/config wiring instead of registry placeholders

## US-007 - Wiring completo de Discord interactions
- Branch: us/us-007-wiring-completo-de-discord-interactions
- Status: complete
- Files: src/supernova/adapters/discord_events.gleam, src/supernova/channel/registry.gleam, test/adapters/discord_events_test.gleam, test/channel/registry_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: tightened `discord_events_test` to require rich application-command and message-component decoding, and expanded `registry_test` with regressions proving slash commands and component interactions are routed to the shared inbound handler
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: `source_message_id` for Discord component interactions is still not preserved from the raw interaction payload, so follow-up targeting still relies on the broader interaction context instead of an explicit source-message field
- Carry forward: `US-008` can mirror the same boundary pattern by normalizing Telegram callback payloads into `ChannelInteractionMessage` / `InboundInteraction` instead of extending core-specific Telegram branches

## US-008 - Wiring completo de Telegram callbacks/inline
- Branch: us/us-008-wiring-completo-de-telegram-callbacks-inline
- Status: complete
- Files: src/supernova/channel/registry.gleam, src/supernova/adapters/channel_common_router.gleam, test/channel/registry_test.gleam, test/adapters/channel_router_test.gleam, tasks/prd.json, tasks/ralph-progress.md, TODO.md
- Tests: added a registry regression proving `callback_query` becomes `InboundInteraction` with `action_id`, `values`, and `source_message_id`, plus a Telegram router regression proving interaction replies now carry `edit_message_id` so inline keyboards are updated in place
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: Telegram callback normalization currently gives special structured treatment only to `picker_model_select:<provider>|<model>`; other callback payload schemes still pass through as raw `action_id`
- Carry forward: `US-009` is now the next eligible story by priority, and the Telegram interaction path no longer blocks the shared interactive UX flow

## US-009 - Implementar Browser tool real
- Branch: us/us-009-browser-tool-real-current
- Status: complete
- Files: src/supernova/tools/browser.gleam, src/supernova/core/executor.gleam, src/supernova_browser_ffi.erl, scripts/browser_runner.mjs, package.json, package-lock.json, .gitignore, test/tools/browser_test.gleam, test/core/executor_test.gleam, tasks/prd.json
- Tests: added a live browser round-trip covering `open/type/click/evaluate/extract_readable/screenshot/close`, added a timeout regression proving timed-out sessions are cleaned up, and expanded executor coverage for browser-tool declaration + invalid argument handling
- Validation: `npm install` passed; `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the browser runner currently targets a host Chrome/Chromium executable via `playwright-core`, so environments without a supported browser binary must provide `SUPERNOVA_BROWSER_EXECUTABLE` or an equivalent Chrome path
- Carry forward: `US-010` can assume the tool-execution loop now supports long-lived external-session tools through Erlang FFI, not only single-shot shell/HTTP helpers

## US-010 - Implementar Sessions Yield
- Branch: us/us-010-implementar-sessions-yield
- Status: complete
- Files: src/supernova/core/executor.gleam, test/core/checkpoint/executor_checkpoint_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: strengthened `executor_checkpoint_test` to prove abort on forced yield, manual pause with saved checkpoint metadata, timeout-driven pause with checkpoint restore, and budget-exhaustion pause preserving `pending_tool`
- Validation: `gleam test test/core/checkpoint/executor_checkpoint_test.gleam` passed; `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the budget-triggered yield path is currently scoped to `BudgetToolCalls`; token-budget exhaustion still depends on higher-level orchestration because the executor does not yet meter LLM token usage itself
- Carry forward: `US-011` can build on an executor that already exposes a cooperative pause API and checkpoint metadata for manual/timeout/budget preemption, which will matter once more long-running tools exist

## US-011 - Implementar Process tool
- Branch: us/us-011-implementar-process-tool
- Status: complete
- Files: src/supernova/tools/process.gleam, src/supernova_process_ffi.erl, src/supernova/core/executor.gleam, test/tools/process_test.gleam, test/core/executor_test.gleam, test/fixtures/process_workspace/agent_1/process_fixture.sh, tasks/prd.json, tasks/ralph-progress.md
- Tests: added `process_test` regressions for list/info/kill round-trip, WorkspacePolicy denial for external processes, and allowlisted workspace-script inspection/termination; expanded `executor_test` to require builtin registration plus invalid-argument handling for the `process` tool
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: authorization is inferred from the visible command line of each process, so processes launched through opaque wrappers still collapse to `/external/<command>` rather than a richer provenance signal
- Carry forward: `US-012` can reuse the now-proven pattern of “tool module + Erlang FFI + executor builtin wiring + focused regression suite” for the remaining real-tool stories

## US-012 - Implementar GitHub tool
- Branch: us/us-012-implementar-github-tool
- Status: complete
- Files: src/supernova/tools/github.gleam, src/supernova/core/executor.gleam, src/supernova/llm/client.gleam, test/tools/github_test.gleam, test/core/executor_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: added `github_test` coverage for YAML/env runtime-config resolution, repository JSON decoding + filtering by language/topic/date, and rendered output; expanded `executor_test` with builtin registration plus invalid-argument handling for the `github` tool
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the validation is parser-heavy and does not hit the live GitHub API, so real-world behavior still depends on a valid token plus GitHub returning the expected `/user/repos` payload shape
- Carry forward: `US-013` now inherits the same “real tool behind executor builtin” pattern, but unlike `US-012` its backlog wording still leaves the actual product scope to be defined

## US-013 - Implementar Canvas tool
- Branch: us/us-013-implementar-canvas-tool
- Status: complete
- Files: src/supernova/tools/canvas.gleam, src/supernova/core/executor.gleam, src/supernova/llm/client.gleam, test/tools/canvas_test.gleam, test/core/executor_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: added `canvas_test` coverage for create/upsert/move/delete/render round-trip on the structured canvas document, and expanded `executor_test` with builtin registration plus invalid-argument handling for the `canvas` tool
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the chosen scope is intentionally non-graphical; `canvas` is now a structured block workspace rather than a pixel/shape drawing API, so any future visual-canvas ambition would need a different contract instead of silently expanding this one
- Carry forward: `US-014` remains the next eligible story, but unlike `US-013` it still has no bounded product scope in the backlog and may become the next real blocker if there is no existing gateway-tool contract to ground it

## US-014 - Implementar Gateway tool
- Branch: us/us-014-implementar-gateway-tool
- Status: complete
- Files: src/supernova/tools/gateway.gleam, src/supernova/core/executor.gleam, src/supernova/llm/client.gleam, test/tools/gateway_test.gleam, test/core/executor_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: added `gateway_test` coverage for `describe`, one-shot `get_budget`, one-shot `write_world`, and auth denial when `register_agent` is disabled; expanded `executor_test` with builtin registration plus invalid-argument handling for the `gateway` tool
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the chosen scope is intentionally stateless between tool calls; this tool exercises the real syscall-gateway pipeline, but it does not keep a persistent gateway actor or agent registration across turns
- Carry forward: `US-015` is now the next eligible story, and it can rely on the executor exposing a broader set of real builtins (`browser`, `canvas`, `gateway`, `process`, `github`, `web_fetch`, `git_inspect`, `file_system`) instead of placeholders

## US-015 - Integrar loop de tools no runtime de canal
- Branch: us/us-015-integrar-loop-de-tools-no-runtime-de-canal
- Status: complete
- Files: src/supernova/llm/client.gleam, test/adapters/channel_router_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: added channel-router regressions proving a Telegram message can complete a builtin-tool loop and return a final response, and that a forced tool-argument failure still returns a final channel reply instead of aborting the router flow
- Validation: `gleam test test/adapters/channel_router_test.gleam` passed (the project runner completed with `1598 passed, no failures`); `gleam format --check src test` passed; `gleam build` passed
- Risks: the new observability hooks live in the mock provider only; production runtime behavior was already present, and this story mainly tightened proof at the router boundary rather than changing executor semantics
- Carry forward: `US-017` is now the next eligible story by priority because `US-016` is already complete, and the channel runtime now has explicit regression coverage for tool-loop success and error propagation

## US-017 - Implementar comandos UX executaveis
- Branch: us/us-017-implementar-comandos-ux-executaveis
- Status: complete
- Files: test/adapters/channel_router_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: expanded the shared channel-router regression suite to cover `/help`, `/start`, `/status`, and `/model` in Discord and Telegram, including Discord bootstrap/status state transitions and the Discord `/model` interactive picker entrypoint
- Validation: `gleam test test/adapters/channel_router_test.gleam` passed (the project runner completed with `1602 passed, no failures`); `gleam format --check src test` passed; `gleam build` passed
- Risks: production code did not need to change for this story; the slice is proof-oriented, so residual risk is mostly around future command drift if router behavior changes without keeping these acceptance regressions in sync
- Carry forward: `US-018` is now the next eligible story, and it inherits a router test suite that already proves the public command entrypoints across Discord and Telegram

## US-018 - Provider/model por botoes com persistencia
- Branch: us/us-018-provider-model-por-botoes-com-persistencia
- Status: complete
- Files: src/supernova/adapters/channel_common_router.gleam, test/adapters/channel_router_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: expanded `channel_router_test.gleam` to prove a selected model persists in session state and surfaces in `/status`, and added a regression proving invalid `picker_model_select` payloads fall back to the default provider/model instead of failing the interaction
- Validation: `gleam test test/adapters/channel_router_test.gleam` passed (runner completed with `1603 passed, no failures`); `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: the model picker state is still kept in the router's in-memory `session_configs`, so this story proves per-session persistence inside the running process, not cross-process durability
- Carry forward: `US-019` should inspect the runtime session path itself because the picker persistence is now verified at the router boundary and the next remaining gap is preserving richer agent/session state across turns

## US-019 - Bootstrapping de agente por sessao
- Branch: us/us-019-bootstrapping-de-agente-por-sessao
- Status: complete
- Files: src/supernova/core/session/server.gleam, src/supernova/core/session/supervisor.gleam, src/supernova/adapters/channel_common_router.gleam, src/supernova/adapters/discord_router.gleam, src/supernova/adapters/telegram_router.gleam, src/supernova.gleam, test/adapters/channel_router_test.gleam, test/core/session/supervisor_test.gleam, tasks/prd.json, tasks/ralph-progress.md
- Tests: added router regressions proving supervised Telegram sessions retain chat history across turns and supervised Discord sessions keep the selected model across router restart; added a supervisor regression proving started sessions expose the rich `session/server` API
- Validation: `gleam test test/adapters/channel_router_test.gleam` passed (runner completed with `1606 passed, no failures`); `gleam test test/core/session/supervisor_test.gleam` passed (runner completed with `1606 passed, no failures`); `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: bootstrapped/not-started UX state still lives in the router's in-memory `session_profiles`, so the richer persisted session trail now covers history + model selection but not yet every per-session UX flag
- Carry forward: `US-021` is now the next eligible story by priority because `US-020` is already closed, and the production routers now have a real supervisor-backed session trail that future typing/chunking work can attach to

## US-021 - Typing indicators no contrato e implementacao
- Branch: us/us-021-typing-indicators-no-contrato-e-implementacao
- Status: blocked
- Files: tasks/prd.json, tasks/ralph-progress.md
- Tests: none; this stopped at backlog/architecture validation before a meaningful red test could be written
- Validation: code inspection only for this story; no project gates rerun because no production code changed on the blocked branch
- Risks: the Port already has `typing` metadata and Telegram already emits `sendChatAction typing`, so forcing this story through as written would likely create a misleading partial implementation rather than satisfying the stated acceptance
- Carry forward: unblock by either narrowing `US-021` to Telegram/Discord pre-send typing without streaming/Slack, or by first adding a real channel-streaming path plus a clarified Slack feedback contract

## Backlog Update - Inserted US-026
- Branch: us/us-021-typing-indicators-no-contrato-e-implementacao
- Status: complete
- Files: tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: none; backlog-only change
- Validation: JSON sanity check passed (`jq` confirmou `US-026` em `priority: 21`, `US-021` re-sequenciada para `priority: 22` com `dependsOn: ["US-002", "US-026"]`)
- Risks: none in runtime; this only re-sequences backlog execution
- Carry forward: `US-026` now becomes the next intended runtime story before `US-021`, and `US-021` depends explicitly on it

## US-026 - Streaming real por canal
- Branch: us/us-026-streaming-real-por-canal
- Status: complete
- Files: src/supernova/channel/port.gleam, src/supernova/adapters/channel_common_router.gleam, src/supernova/adapters/discord_router.gleam, src/supernova/adapters/telegram_router.gleam, src/supernova/channel/registry.gleam, src/supernova/adapters/discord_rest.gleam, src/supernova.gleam, test/channel/registry_test.gleam, test/adapters/channel_router_test.gleam, test/adapters/google_chat_adapter_test.gleam, test/adapters/lark_adapter_test.gleam, test/adapters/mattermost_adapter_test.gleam, test/adapters/wechat_work_adapter_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: added registry regressions proving Discord emits a placeholder and edits the same message during stream while Telegram performs typing + send/edit progressivo; added a router regression proving the supervised Telegram session records only the final streamed assistant content in rich session history
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1609 passed, no failures`)
- Risks: provider-side live streaming depth still depends on the underlying `executor.run_stream` path; when it does not yield usable chunks (or yields tool-call deltas), the runtime now falls back safely to `executor.run(...)` instead of hanging
- Carry forward: `US-021` is now unblocked from the runtime-streaming perspective, but it still needs a reduced/clarified product contract for Slack and a real Discord typing endpoint before it can be closed

## US-021 - Typing indicators no contrato e implementacao (re-check after US-026)
- Branch: us/us-026-streaming-real-por-canal
- Status: blocked
- Files: tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: none; this stopped at backlog/product-contract validation after the streaming runtime dependency was removed
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed on the `US-026` branch before this re-check
- Risks: forcing the story as written would produce a misleading partial close because Telegram is ready enough for typing, but Discord still lacks `/channels/{id}/typing` wiring and Slack still has no request-driven typing indicator in the current transport model
- Carry forward: next action is to renegotiate `US-021` to Discord/Telegram only or otherwise replace the Slack criterion with a transport-valid feedback contract, then implement the Discord typing endpoint and keepalive/stop loop

## US-021 - Typing indicators no contrato e implementacao
- Branch: us/us-026-streaming-real-por-canal
- Status: complete
- Files: src/supernova/adapters/discord_rest.gleam, src/supernova/channel/registry.gleam, test/channel/registry_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: updated registry regressions so Discord now proves initial typing plus keepalive refresh while a stream is idle, and Telegram proves the same keepalive behavior using the same runtime loop
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed
- Risks: Slack still does not have progress feedback in the runtime; that product gap was intentionally split out instead of being hidden behind an invalid typing criterion
- Carry forward: `US-027` now tracks the transport-valid Slack follow-up as progressive Web API feedback rather than request-driven typing

## Backlog Update - Added US-027
- Branch: us/us-026-streaming-real-por-canal
- Status: complete
- Files: tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: none; backlog-only change
- Validation: JSON remained valid after inserting the new story
- Risks: none in runtime; this preserves the Slack gap explicitly instead of leaving it implicit after narrowing `US-021`
- Carry forward: next logical backlog item remains the first pending story by priority after the now-closed `US-021`

## Backlog Update - Post-PRD parity expansion
- Branch: us/us-026-streaming-real-por-canal
- Status: complete
- Files: tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: none; backlog-only change
- Validation: JSON remained valid after appending `US-028` and `US-029`
- Risks: none in runtime; this only records future parity work without changing the current PRD execution order
- Carry forward: the current PRD remains unchanged in practical execution scope and still targets complete parity only for Discord and Telegram

## US-022 - Chunking inteligente por limite de canal
- Branch: us/us-022-chunking-inteligente-por-limite-de-canal
- Status: complete
- Files: src/supernova/channel/chunking.gleam, src/supernova/channel/registry.gleam, src/supernova/adapters/slack_adapter.gleam, test/channel/chunking_test.gleam, test/channel/registry_test.gleam, test/adapters/slack_adapter_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: added shared chunking regressions for continuation markers and fenced markdown balance; added registry regressions proving Discord and Telegram split oversized sends into bounded chunks; added Slack adapter regression proving multi-payload rendering preserves `thread_ts` and continuation text
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1617 passed, no failures`)
- Risks: stream-time chunking is still a separate concern from the normal send path; this story closes bounded outbound delivery for non-stream sends and Slack payload rendering, but does not change how progressively edited stream messages eventually need per-channel hard-limit handling
- Carry forward: the next pending story by PRD order is `US-023`, and it should be evaluated against the already-landed session supervisor work from `US-019`

## US-023 - Unificar sessao minima com sessao rica
- Branch: us/us-023-unificar-sessao-minima-com-sessao-rica
- Status: complete
- Files: src/supernova/channel/session.gleam, src/supernova/adapters/telegram_router.gleam, src/supernova/adapters/discord_router.gleam, src/supernova.gleam, test/channel/session_test.gleam, test/adapters/channel_router_test.gleam, src/supernova/adapters/discord_session.gleam, src/supernova/adapters/telegram_session.gleam, test/adapters/discord_session_test.gleam, test/adapters/telegram_session_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: added canonical session-id regressions in `channel/session`; updated router regressions to derive supervised-session lookups from canonical IDs instead of adapter-specific managers; removed obsolete dedicated manager tests with the deleted modules
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1607 passed, no failures`)
- Risks: this closes runtime session duplication for Discord/Telegram, but channels still using `without_manager(...)` remain on simple deterministic IDs until their own richer runtime stories are implemented
- Carry forward: `US-024` is now the next pending PRD story, and it should be checked against the current `config` surface versus the providers the LLM client actually routes at runtime

## US-024 - Alinhar config/providers com runtime efetivo
- Branch: us/us-024-alinhar-config-providers-com-runtime-efetivo
- Status: complete
- Files: src/supernova/config.gleam, src/supernova.gleam, src/supernova/llm/client.gleam, src/supernova/llm/providers/ollama.gleam, src/supernova/llm/providers_info.gleam, src/supernova/wizard.gleam, test/config/config_test.gleam, test/llm/provider_test.gleam, test/wizard/wizard_test.gleam, README.md, examples/quickstart/supernova.yaml, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: expanded config parsing coverage for `provider:` and legacy `type:` plus all newly exposed providers; added client dispatch regressions proving OpenRouter, OpenCode Zen, Zhipu, Zhipu Coding, and MiniMax hit real provider paths; added wizard regression proving generated YAML now uses `providers.default.provider`
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1618 passed, no failures`)
- Risks: `timeout_ms` is still config-only metadata and not yet consumed by the low-level provider HTTP clients; this story aligned provider routing/runtime coverage, not per-request timeout plumb-through
- Carry forward: `US-025` is now the next pending PRD story, and it should be evaluated against the current channel runtime/tests to see whether the missing coverage is mostly harness work or if more production wiring is still absent

## US-025 - Testes E2E Port Adapter Executor Canal
- Branch: us/us-025-testes-e2e-port-adapter-executor-canal
- Status: complete
- Files: src/supernova/llm/client.gleam, src/supernova/core/executor.gleam, src/supernova/channel/registry.gleam, test/channel/registry_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: added registry-level E2E coverage that runs real Discord/Telegram inbound events through the production routers and channel runtime, covering `/help`, Telegram callback-driven UI edit plus selected-model propagation into the next executor-backed reply, stream fallback on error, stream fallback on timeout, and invalid callbacks that produce no outbound send
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1623 passed, no failures`)
- Risks: the deterministic mock seams for `[stream-error]`, `[stream-timeout]`, and `[echo-model]` live only in the mock executor/provider path; they make the E2E harness precise without increasing coverage of external provider-specific transport failures
- Carry forward: `US-027` is now the next pending PRD story, and it should be evaluated against the current Slack adapter/runtime surface because the backlog item was created precisely to replace the earlier invalid Slack typing criterion

## US-027 - Feedback progressivo nativo no Slack
- Branch: us/us-027-feedback-progressivo-nativo-no-slack
- Status: complete
- Files: src/supernova/adapters/slack_adapter.gleam, src/supernova/channel/registry.gleam, src/supernova.gleam, test/adapters/slack_adapter_test.gleam, test/channel/registry_test.gleam, tasks/prd.json, TODO.md, tasks/ralph-progress.md
- Tests: added adapter regressions for Slack progress-mode selection and `chat.*Stream` payload builders; added registry regressions proving native Slack progress start/append/stop for DM-thread replies and non-typing fallback send/edit updates for threaded channel replies
- Validation: `gleam format --check src test` passed; `gleam build` passed; `gleam test` passed (`1630 passed, no failures`)
- Risks: the current ChannelReply/runtime surface still does not carry Slack `recipient_team_id`, so native `chat.*Stream` is used directly for DM-thread replies while threaded public-channel replies use `postMessage/update` fallback until the broader Slack parity work in `US-028`
- Carry forward: the PRD itself is now fully green; the remaining backlog items are post-PRD parity expansions `US-028` and `US-029`
