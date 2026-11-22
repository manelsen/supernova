# TODO — Paridade real de implementação (Supernova x OpenClaw)

Base desta lista:
- feita somente por análise de código (`src/` e `test/`), sem usar documentação markdown como fonte.
- foco em Port/Adapters, UI/UX de comandos e botões, seleção provider/model e bootstrap por canal.

---

## 1) Estado atual confirmado no código do Supernova

- [x] Existe contrato de canal mínimo em `src/supernova/channel/port.gleam` (`ChannelMessage`, `ChannelReply`, `ChannelHandler`, `ChannelAdapter`).
- [x] Existe roteamento comum por canal em `channel_common_router` + routers específicos (`discord_router`, `telegram_router`) e genéricos (`matrix/slack/lark/..._router`).
- [x] Existem módulos ricos de baixo nível para Discord (`discord_gateway`, `discord_events`, `discord_rest`, `discord_commands`).
- [x] Existe módulo de baixo nível para Telegram com polling, parse de updates/callbacks e envio/edição de mensagens (`telegram.gleam`).
- [x] Existe wizard CLI para gerar `supernova.yaml` com canais e tokens.
- [x] Existe executor com loop, streaming e checkpoint/yield.
- [x] Existem providers `openrouter`, `opencode_zen`, `zhipu`, `zhipu_coding`, `minimax` roteados no `llm/client`.

---

## 2) Referência de paridade observada no código do OpenClaw

- [x] Payload interativo estruturado (`text/buttons/select`) e normalização cross-channel.
- [x] Seleção de provider/model por UI (Discord model picker e Telegram model buttons).
- [x] Outbound adapters com chunking por limite de canal, mídia e threading.
- [x] UX de typing e reactions em runtime.
- [x] Dispatcher com estágios `tool/block/final` e callbacks de tool result.

---

## 3) Backlog priorizado (gap real)

### P0 — Bloqueadores de produto / UX

- [x] **Ligar bootstrap real de canais no `main`** (start/stop de Discord/Telegram e ciclo de shutdown).
  - Implementado em `us/us-001-ligar-bootstrap-de-canais-no-main`: `supernova.gleam` agora cria um `ChannelHandler` real com `discord_router` + `telegram_router`, `channel/registry` liga inbound Discord/Telegram ao `channel_common_router`, e o shutdown espera cleanup dos workers/bridges de canal.
  - Nota de validação: `gleam build`, `gleam test` e `gleam format --check src test` passam. `docker compose up -d postgres` também passa com remapeamento temporário da porta do host para `127.0.0.1:5433`.

- [x] **Conectar Port ↔ Adapter de ponta a ponta** (`start(handler) -> ChannelAdapter`) em vez de módulos soltos.
  - Implementado em `us/us-002-conectar-port-adapter-de-ponta-a-ponta`: `ChannelAdapter` agora carrega `send` + `stop`, `channel/registry` passou a armazenar adapters genéricos do Port em vez de `ChannelEntry`, e os canais iniciados retornam adapters reais com marshaling/propagação de erro centralizados no contrato.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Evoluir `ChannelReply` para payload rico** (interativo, mídia, metadados de UX).
  - Implementado em `us/us-016-evoluir-channelreply-para-payload-rico`: `ChannelReply` agora carrega componentes interativos, variantes de mídia (`image/audio/document`) e metadados de UX (`thread_id`, `typing`, `edit_message_id`); `discord_rest` ganhou components nativos; `telegram.gleam` ganhou `reply_markup` para inline keyboards; e `slack_adapter` deixou de serializar blocks como strings JSON.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [ ] **Implementar comandos de UX realmente executáveis por canal** (`/help`, `/start`, `/status`, `/model`).
  - Aceite: comandos retornam respostas funcionais em Discord e Telegram (não só texto estático em `core/ux.gleam`).

- [ ] **Provider/model por botões/menus (não por texto livre)** com persistência por sessão.
  - Aceite: usuário escolhe provider/model via componentes (Discord) e inline buttons (Telegram); escolha afeta chamadas seguintes do executor.

- [ ] **Bootstrapping de agente por sessão no channel flow** (histórico, contexto e override de modelo).
  - Aceite: mensagens consecutivas no mesmo chat preservam contexto de sessão e modelo selecionado.

- [ ] **Integrar loop de tools no runtime de canal** (execução real e retorno de resultado de ferramenta).
  - Aceite: tool calls deixam de ser placeholder; tool result volta ao loop até resposta final.

### P1 — Paridade funcional de canais

- [x] **Threading/reply-to real em todos adapters** usando `reply_to_id`.
  - Implementado em `us/us-020-adicionar-thread-id-a-channelreply`: Matrix agora usa `thread_id` explícito antes de cair para `reply_to_id`, Telegram ganhou `message_thread_id` no low-level client e no send path do registry, e os caminhos já existentes de Discord/Slack continuaram verdes com o contrato novo.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam; um artefato corrompido temporário do runner BEAM foi resolvido com `gleam clean`.

- [x] **Streaming real por canal**.
  - Implementado em `us/us-026-streaming-real-por-canal`: o Port ganhou `ImmediateReply | StreamReply`, o runtime real de canal passou a consumir updates progressivos, Discord agora envia placeholder e edita a mesma mensagem durante o stream, e Telegram faz `send/edit` progressivo preservando histórico/modelo no `StreamComplete`.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Typing/status/reactions no contrato e na implementação**.
  - Implementado no mesmo branch de `US-026`: Discord ganhou endpoint real de typing no `discord_rest`, e o runtime do `registry` agora emite typing no início do turn e faz keepalive durante lacunas do stream em Discord/Telegram, parando ao completar/falhar/timeout.
  - Nota: o critério antigo de Slack foi removido desta story porque era inválido para o transporte atual; o gap real foi reaberto como item próprio de feedback progressivo no Slack.

- [x] **Feedback progressivo nativo no Slack**.
  - Implementado em `us/us-027-feedback-progressivo-nativo-no-slack`: `slack_adapter.gleam` agora expõe primitivas de progresso para `chat.startStream/appendStream/stopStream` e fallback via `chat.update`, enquanto `channel/registry.gleam` passou a registrar um `send_stream` real para Slack. A suíte cobre stream nativo em DM/thread e fallback sem typing para channel threads, sempre preservando `thread_ts` efetivo.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Chunking e limites por canal** (texto longo, componentes, mídia).
  - Implementado em `us/us-022-chunking-inteligente-por-limite-de-canal`: `supernova/channel/chunking` centraliza o split por limite com continuation marker, preservação de metadata e reabertura/fecho seguro de fenced code blocks; o `registry` agora divide replies longos para Discord (2000) e Telegram (4096), e o adapter do Slack envia múltiplos payloads até 40000 chars preservando `thread_ts`.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [ ] **Substituir routers genéricos por adapters de canal reais** (Matrix, Lark, Google Chat, Slack, Mattermost, WeChat Work, WhatsApp).
  - Aceite: deixam de ser apenas wrappers de `generic_channel_router` e passam a consumir protocolo nativo.
  - Progresso: Matrix foi fechado em `us/us-003-criar-matrix-adapter-nativo` com parse nativo de edits/redactions e outbound `text + html` / `m.replace`; Slack foi fechado em `us/us-004-criar-slack-adapter-nativo` com parse real de `event_callback` e Block Kit interativo corrigido; WhatsApp foi fechado em `us/us-005-criar-whatsapp-adapter-nativo` com webhook/payload bridge oficial, outbound real para `/send/message|image|audio|file`, config `bridge_url + device_id` e bootstrap no registry; Lark/Google Chat/Mattermost/WeChat Work foram fechados em `us/us-006-criar-adapters-restantes-google-chat-lark-mattermost-wechat-work` com bootstrap real no registry, config/wizard específicos de runtime e adapters nativos de envio. O item segue aberto apenas porque os routers ainda delegam ao `generic_channel_router` no nível de orquestração compartilhada.

- [x] **Wiring completo de Discord interactions** (`discord_gateway/events/commands` -> router -> core -> resposta).
  - Implementado em `us/us-007-wiring-completo-de-discord-interactions`: `discord_events.gleam` passou a decodificar `INTERACTION_CREATE` em application commands e message components ricos, e `channel/registry.gleam` agora transforma essas interactions em `InboundMessage` / `InboundInteraction` reais para o fluxo compartilhado.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Wiring completo de Telegram callbacks/inline** (`callback_query` + inline keyboard).
  - Implementado em `us/us-008-wiring-completo-de-telegram-callbacks-inline`: `channel/registry.gleam` passou a transformar `callback_query` em `InboundInteraction` com `action_id`, `values` e `source_message_id`, e `channel_common_router.gleam` agora propaga `edit_message_id` em interacoes do Telegram para que a mensagem inline seja atualizada no lugar.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

### P2 — Coerência de arquitetura

- [x] **Unificar sessão mínima (`supervisor`) com sessão rica (`session/server`)** no fluxo de produção.
  - Implementado em `us/us-023-unificar-sessao-minima-com-sessao-rica`: Discord e Telegram deixaram de manter `session_mgr` paralelos só para mapear IDs, passaram a resolver IDs canônicos direto em `channel/session`, e o runtime ficou com uma única trilha ativa de sessão via `session/supervisor` + `session/server`. Os antigos módulos `discord_session` e `telegram_session` foram removidos junto com os testes dedicados.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Alinhar config/providers com runtime efetivo do cliente LLM** (evitar provider “válido” na config mas não roteado no client).
  - Implementado em `us/us-024-alinhar-config-providers-com-runtime-efetivo`: `config.gleam` agora expõe só providers realmente roteados (`openai`, `anthropic`, `openrouter`, `opencode_zen`, `zhipu`, `zhipu_coding`, `minimax`, `ollama`), aceita `provider:` e `type:` por compatibilidade, e `supernova.gleam` converte esse enum para nomes/default models do runtime de forma exaustiva. O wizard passou a gerar `providers.default.provider`, `providers_info.gleam` foi reduzido ao conjunto suportado, e a suíte ganhou regressões de parser e dispatch para OpenRouter/OpenCode Zen/Zhipu/Zhipu Coding/MiniMax.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

- [x] **Adicionar testes de integração E2E Port→Adapter→Executor→Canal** para comandos, botões e seleção de modelo.
  - Implementado em `us/us-025-testes-e2e-port-adapter-executor-canal`: `test/channel/registry_test.gleam` agora sobe o runtime real com `discord_router` + `telegram_router` e cobre `/help` vindo de slash interaction, callback do Telegram editando a UI e alterando a resposta seguinte do executor, além dos erros críticos de stream fallback, timeout e callback inválido. O mock executor/provider ganhou seams determinísticos só para os cenários `[stream-error]`, `[stream-timeout]` e `[echo-model]`, e o recorder de outbound do registry passou a refletir edits imediatos corretamente.
  - Nota de validação: `gleam format --check src test`, `gleam build` e `gleam test` passam.

### Pós-PRD — Expansão de Paridade

- [ ] **Levar Slack a paridade completa com Discord e Telegram**.
  - Aceite: Slack sai do modo “adapter nativo + feedback dedicado” e ganha runtime/sessão/comandos/interações/E2E equivalentes aos canais principais.

- [ ] **Levar Matrix a paridade completa com Discord e Telegram**.
  - Aceite: Matrix preserva seus recursos nativos de thread/edit, mas também ganha a mesma trilha de sessão, comandos e E2E ponta a ponta dos canais principais.

- [ ] **Nota de escopo**.
  - A PRD atual fecha com paridade completa apenas em `Discord` e `Telegram`. `Slack` e `Matrix` ficam como expansão pós-PRD; `WhatsApp`, `Lark`, `Google Chat`, `Mattermost` e `WeChat Work` permanecem em escopo de adapter/protocolo, não de paridade total de produto.
