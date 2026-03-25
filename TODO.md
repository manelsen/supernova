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

- [ ] **Ligar bootstrap real de canais no `main`** (start/stop de Discord/Telegram e ciclo de shutdown).
  - Aceite: `supernova.gleam` deixa de ter TODOs de start/stop de canais; inbound real chega ao roteador.

- [ ] **Conectar Port ↔ Adapter de ponta a ponta** (`start(handler) -> ChannelAdapter`) em vez de módulos soltos.
  - Aceite: cada canal inicializado retorna adapter com `send` usado pelo core; core não depende de módulo concreto.

- [ ] **Evoluir `ChannelReply` para payload rico** (interativo, mídia, metadados de UX).
  - Aceite: contrato do Port cobre botões/select/media, não apenas `content` + `reply_to_id`.

- [ ] **Implementar comandos de UX realmente executáveis por canal** (`/help`, `/start`, `/status`, `/model`).
  - Aceite: comandos retornam respostas funcionais em Discord e Telegram (não só texto estático em `core/ux.gleam`).

- [ ] **Provider/model por botões/menus (não por texto livre)** com persistência por sessão.
  - Aceite: usuário escolhe provider/model via componentes (Discord) e inline buttons (Telegram); escolha afeta chamadas seguintes do executor.

- [ ] **Bootstrapping de agente por sessão no channel flow** (histórico, contexto e override de modelo).
  - Aceite: mensagens consecutivas no mesmo chat preservam contexto de sessão e modelo selecionado.

- [ ] **Integrar loop de tools no runtime de canal** (execução real e retorno de resultado de ferramenta).
  - Aceite: tool calls deixam de ser placeholder; tool result volta ao loop até resposta final.

### P1 — Paridade funcional de canais

- [ ] **Threading/reply-to real em todos adapters** usando `reply_to_id`.
  - Aceite: respostas em thread/reply no Discord/Slack/Telegram quando houver referência.

- [ ] **Typing/status/reactions no contrato e na implementação**.
  - Aceite: adapters suportam typing e feedback de status durante runs longos.

- [ ] **Chunking e limites por canal** (texto longo, componentes, mídia).
  - Aceite: envio respeita limites de cada canal (ex.: Discord 2000 chars) sem perda silenciosa.

- [ ] **Substituir routers genéricos por adapters de canal reais** (Matrix, Lark, Google Chat, Slack, Mattermost, WeChat Work, WhatsApp).
  - Aceite: deixam de ser apenas wrappers de `generic_channel_router` e passam a consumir protocolo nativo.

- [ ] **Wiring completo de Discord interactions** (`discord_gateway/events/commands` -> router -> core -> resposta).
  - Aceite: slash commands + component interactions disparam handlers reais no fluxo do bot.

- [ ] **Wiring completo de Telegram callbacks/inline** (`callback_query` + inline keyboard).
  - Aceite: callback data chega ao core e atualiza estado/modelo/comandos.

### P2 — Coerência de arquitetura

- [ ] **Unificar sessão mínima (`supervisor`) com sessão rica (`session/server`)** no fluxo de produção.
  - Aceite: uma única trilha de sessão ativa no runtime, sem duplicidade de modelos de estado.

- [ ] **Alinhar config/providers com runtime efetivo do cliente LLM** (evitar provider “válido” na config mas não roteado no client).
  - Aceite: providers expostos no config têm execução real e teste de integração.

- [ ] **Adicionar testes de integração E2E Port→Adapter→Executor→Canal** para comandos, botões e seleção de modelo.
  - Aceite: suíte cobre happy-path e erros de UX críticos (fallback, timeout, callback inválido).
