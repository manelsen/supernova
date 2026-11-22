# Supernova Implementation TODO

**Status atual:** Kernel completo (100%), Canais parciais (20%), Tools básicos (40%), UX imaturo (10%)

**Última atualização:** 2026-03-26

---

## P0 - CRÍTICO: Canais Scaffolded → Implementação Nativa

### 1.1 Matrix Channel (Priority: HIGH)
- [ ] **Implementar Matrix client SDK integration**
  - [ ] Adicionar dependência `matrix_sdk` ou equivalente Gleam/Erlang
  - [ ] Implementar autenticação via access token
  - [ ] Implementar webhook receiver para eventos
  - [ ] Implementar message sender (text + markdown)
  - [ ] Implementar `MatrixSessionManager` (supervisor)
  - [ ] Adicionar tests de integração

- [ ] **Criar `matrix_adapter.gleam`**
  - [ ] Normalizar eventos Matrix → `ChannelMessage`
  - [ ] Converter `ChannelReply` → Matrix message format
  - [ ] Suportar threads (reply_to_id)
  - [ ] Suportar edits/deletes
  - [ ] Tratar errors específicos do Matrix

- [ ] **Remover `matrix_router.gleam` (scaffold)**
  - [ ] Migrar para `matrix_adapter.gleam`
  - [ ] Atualizar `supernova.gleam` para inicializar Matrix corretamente

**Aceite:** Bot Matrix responde a mensagens, preserva contexto de sessão, suporta threading

---

### 1.2 Slack Channel (Priority: HIGH)
- [ ] **Implementar Slack SDK integration**
  - [ ] Adicionar dependência Slack (via FFI Erlang ou HTTP)
  - [ ] Implementar OAuth 2.0 flow
  - [ ] Implementar Socket Mode ou Events API
  - [ ] Implementar message sender (text + blocks + attachments)
  - [ ] Implementar `SlackSessionManager`
  - [ ] Adicionar tests de integração

- [ ] **Criar `slack_adapter.gleam`**
  - [ ] Normalizar Slack events → `ChannelMessage`
  - [ ] Converter `ChannelReply` → Slack blocks format
  - [ ] Suportar interactive components (buttons, select menus)
  - [ ] Suportar app mentions e DMs
  - [ ] Tratar rate limits específicos do Slack

- [ ] **Remover `slack_router.gleam` (scaffold)**
  - [ ] Migrar para `slack_adapter.gleam`
  - [ ] Atualizar `supernova.gleam` para inicializar Slack

**Aceite:** Bot Slack responde a mensagens e app mentions, suporta botões interativos, preserva contexto

---

### 1.3 WhatsApp Channel (Priority: MEDIUM)
- [ ] **Implementar WhatsApp Business API integration**
  - [ ] Decidir: WhatsApp Cloud API ou on-premise?
  - [ ] Implementar webhook receiver
  - [ ] Implementar message sender (text + media)
  - [ ] Implementar template messages (requisito WhatsApp)
  - [ ] Implementar `WhatsAppSessionManager`
  - [ ] Adicionar tests de integração

- [ ] **Criar `whatsapp_adapter.gleam`**
  - [ ] Normalizar WhatsApp webhooks → `ChannelMessage`
  - [ ] Converter `ChannelReply` → WhatsApp format
  - [ ] Suportar media messages (imagem, áudio, documento)
  - [ ] Tratar erro de template messaging

- [ ] **Remover `whatsapp_router.gleam` (scaffold)**

**Aceite:** Bot WhatsApp responde a mensagens, suporta mídia, respeita templates do WhatsApp

---

### 1.4 Google Chat (Priority: LOW)
- [ ] **Implementar Google Chat SDK**
- [ ] **Criar `google_chat_adapter.gleam`**
- [ ] **Remover `google_chat_router.gleam` (scaffold)**

---

### 1.5 Lark/Feishu (Priority: LOW)
- [ ] **Implementar Lark Open API**
- [ ] **Criar `lark_adapter.gleam`**
- [ ] **Remover `lark_router.gleam` (scaffold)**

---

### 1.6 Mattermost (Priority: LOW)
- [ ] **Implementar Mattermost API + WebSocket**
- [ ] **Criar `mattermost_adapter.gleam`**
- [ ] **Remover `mattermost_router.gleam` (scaffold)**

---

### 1.7 WeChat Work (Priority: LOW)
- [ ] **Implementar WeChat Work API**
- [ ] **Criar `wechat_work_adapter.gleam`**
- [ ] **Remover `wechat_work_router.gleam` (scaffold)**

---

## P1 - CRÍTICO: Tools Not Implemented

### 2.1 Browser Tool (Priority: HIGH)
- [ ] **Implementar `browser` tool**
  - [ ] Decidir: Puppeteer (via FFI) ou Playwright (via FFI)?
  - [ ] Implementar FFI Erlang para browser automation
  - [ ] Suportar: open, screenshot, click, type, evaluate, extract_readable
  - [ ] Adicionar timeout e cleanup
  - [ ] Adicionar tests de integração

- [ ] **Remover stub do `execute_browser`**
  ```gleam
  // Hoje: Error("browser tool is not implemented in this runtime")
  // Depois: implementação real via FFI
  ```

**Aceite:** Agentes podem navegar em sites, tirar screenshots, extrair conteúdo

---

### 2.2 Process Tool (Priority: MEDIUM)
- [ ] **Implementar `process` tool**
  - [ ] Listar processos em execução
  - [ ] Matar processo por PID
  - [ ] Obter info de processo (CPU, memória)
  - [ ] Integrar com `WorkspacePolicy` (segurança!)

- [ ] **Remover stub do `execute_process`**
  ```gleam
  // Hoje: Error("process tool is not implemented in this runtime")
  ```

**Aceite:** Agentes podem gerenciar processos com segurança (policy-controlled)

---

### 2.3 GitHub Tool (Priority: LOW)
- [ ] **Implementar `get_my_github_repos`**
  - [ ] Autenticação via GitHub token
  - [ ] Listar repositórios do usuário
  - [ ] Filtrar por linguagem, tema, data

- [ ] **Remover stub do `execute_get_my_github_repos`**

**Aceite:** Agentes podem acessar repositórios GitHub do usuário

---

### 2.4 Canvas Tool (Priority: LOW)
- [ ] **Definir escopo do `canvas` tool**
- [ ] **Implementar conforme especificação**
- [ ] **Remover stub do `execute_canvas`**

---

### 2.5 Sessions Yield (Priority: HIGH)
- [ ] **Implementar `sessions_yield`**
  - [ ] Integrar com `CheckpointProtocol`
  - [ ] Suportar yield por budget exhaustion
  - [ ] Suportar yield por timeout
  - [ ] Suportar yield manual

- [ ] **Remover stub do `execute_sessions_yield`**

**Aceite:** Agentes podem yield execution voluntariamente ou forçadamente

---

### 2.6 Gateway Tool (Priority: MEDIUM)
- [ ] **Definir escopo do `gateway` tool**
- [ ] **Implementar conforme especificação**
- [ ] **Remover stub do `execute_gateway`**

---

## P2 - CRÍTICO: UX Interativa

### 3.1 Botões e Menus para Seleção de Provider/Model (Priority: HIGH)
- [ ] **Evoluir `ChannelReply` para payload rico**
  ```gleam
  pub type ChannelReply {
    TextReply(content: String, reply_to_id: Option(String))
    InteractiveReply(
      content: String,
      components: List(Component),  // buttons, select menus
      reply_to_id: Option(String)
    )
  }
  ```

- [ ] **Implementar componentes visuais**
  - [ ] Discord: Buttons, Select Menus
  - [ ] Telegram: Inline Keyboards
  - [ ] Slack: Blocks (actions, select)

- [ ] **Implementar seleção de provider/model**
  - [ ] Comando `/model` mostra opções interativas
  - [ ] Seleção persiste por sessão
  - [ ] Fallback para provider default

**Aceite:** Usuário seleciona provider/model via botões, não texto livre

---

### 3.2 Comandos /help, /start, /status, /model (Priority: HIGH)
- [ ] **Implementar `/help`**
  - [ ] Listar comandos disponíveis
  - [ ] Mostrar shortcuts do canal
  - [ ] Formatar conforme canal (markdown vs plain text)

- [ ] **Implementar `/start`**
  - [ ] Iniciar nova sessão
  - [ ] Resetar contexto
  - [ ] Mostrar mensagem de boas-vindas

- [ ] **Implementar `/status`**
  - [ ] Mostrar provider/model atual
  - [ ] Mostrar budget restante
  - [ ] Mostrar memória usada
  - [ ] Mostrar uptime da sessão

- [ ] **Implementar `/model`**
  - [ ] Mostrar provider/model atual
  - [ ] Permitir troca interativa
  - [ ] Persistir escolha na sessão

**Aceite:** Todos os comandos funcionam em Telegram e Discord

---

### 3.3 Threading/Reply-to Real (Priority: MEDIUM)
- [ ] **Implementar threading em todos adapters**
  - [ ] Discord: reply_to_id → create message with message_reference
  - [ ] Telegram: reply_to_id → send reply
  - [ ] Slack: thread_ts → post in thread
  - [ ] Matrix: rel_type → m.thread

- [ ] **Evoluir `ChannelReply`**
  ```gleam
  pub type ChannelReply {
    TextReply(
      content: String,
      reply_to_id: Option(String),  // Já existe!
      thread_id: Option(String)      // NOVO
    )
  }
  ```

**Aceite:** Respostas acontecem em thread quando há referência

---

### 3.4 Typing Indicators (Priority: LOW)
- [ ] **Implementar typing em todos adapters**
  - [ ] Discord: channel.trigger_typing_indicator()
  - [ ] Telegram: sendChatAction
  - [ ] Slack: indicador via app mentions

- [ ] **Adicionar ao executor**
  - [ ] Enviar typing no início do turn
  - [ ] Manter durante streaming
  - [ ] Parar ao finalizar

**Aceite:** Usuário vê typing indicator durante processamento

---

### 3.5 Chunking por Limite de Canal (Priority: MEDIUM)
- [ ] **Implementar chunking inteligente**
  - [ ] Discord: 2000 chars
  - [ ] Telegram: 4096 chars
  - [ ] Slack: 40000 chars
  - [ ] WhatsApp: 4096 chars

- [ ] **Respeitar limits de mídia**
  - [ ] Discord: 25MB
  - [ ] Telegram: 50MB (premium), 2MB (free)
  - [ ] Slack: 1GB (paid), 50MB (free)

- [ ] **Split inteligente**
  - [ ] Não quebrar no meio de palavras
  - [ ] Respeitar markdown boundaries
  - [ ] Adicionar continuations quando necessário

**Aceite:** Mensagens longas são divididas sem perda de conteúdo ou formatação

---

## P3 - CRÍTICO: Arquitetura

### 4.1 Bootstrap Real de Canais no Main (Priority: HIGH)
- [ ] **Remover TODOs de `supernova.gleam`**
  - [ ] Implementar start/stop de Discord
  - [ ] Implementar start/stop de Telegram
  - [ ] Implementar ciclo de shutdown limpo

- [ ] **Conectar inbound real ao router**
  - [ ] Discord events → discord_router
  - [ ] Telegram updates → telegram_router

**Aceite:** `supernova.gleam` não tem mais TODOs de canais

---

### 4.2 Port ↔ Adapter Wiring (Priority: HIGH)
- [ ] **Implementar `ChannelAdapter` protocol**
  ```gleam
  pub type ChannelAdapter {
    ChannelAdapter(
      send: fn(ChannelReply) -> Result(Nil, String)
    )
  }
  ```

- [ ] **Cada canal retorna adapter**
  - [ ] `discord.start() -> Result(ChannelAdapter, Error)`
  - [ ] `telegram.start() -> Result(ChannelAdapter, Error)`

- [ ] **Core usa adapter, não módulo concreto**
  - [ ] Desacoplar core de implementações específicas

**Aceite:** Core não depende de módulos concretos de canal

---

### 4.3 ChannelReply Rico (Priority: HIGH)
- [ ] **Evoluir `ChannelReply`**
  ```gleam
  pub type ChannelReply {
    TextReply(content: String, reply_to_id: Option(String))
    InteractiveReply(
      content: String,
      components: List(Component),
      reply_to_id: Option(String)
    )
    MediaReply(
      media_type: MediaType,
      url: String,
      caption: Option(String),
      reply_to_id: Option(String)
    )
  }

  pub type Component {
    Button(id: String, label: String, style: ButtonStyle)
    SelectMenu(id: String, options: List(SelectOption))
    // ...
  }
  ```

**Aceite:** Contrato do Port cobre botões/select/media

---

### 4.4 Loop de Tools no Runtime (Priority: HIGH)
- [ ] **Integrar tool calls no executor**
  - [ ] Tool calls deixam de ser placeholder
  - [ ] Tool result volta ao loop
  - [ ] Loop continua até resposta final

- [ ] **Suportar tool calls em paralelo**
  - [ ] Detectar tools independentes
  - [ ] Executar em paralelo
  - [ ] Agregar resultados

**Aceite:** Tool calls funcionam end-to-end

---

### 4.5 Sessão Unificada (Priority: MEDIUM)
- [ ] **Unificar `session/supervisor` com `session/server`**
  - [ ] Uma única trilha de sessão ativa
  - [ ] Remover duplicidade de modelos de estado

- [ ] **Definir qual modelo usar**
  - [ ] Supervisor: mínimo, OTP-driven
  - [ ] Server: rico, com contexto e histórico

**Aceite:** Não há mais dois modelos de sessão concorrentes

---

## P4 - TESTES E DOCUMENTAÇÃO

### 5.1 Testes de Integração E2E (Priority: MEDIUM)
- [ ] **Adicionar suíte de testes E2E**
  - [ ] Happy path: mensagem → resposta
  - [ ] Tool call: tool → resultado → resposta
  - [ ] Seleção de model: /model → escolha → confirmação
  - [ ] Threading: reply → resposta em thread
  - [ ] Timeout: mensagem longa → timeout → gracefully handled

- [ ] **Testes por canal**
  - [ ] Discord E2E tests
  - [ ] Telegram E2E tests
  - [ ] Slack E2E tests (quando implementado)

**Aceite:** Suíte cobre cenários críticos de UX

---

### 5.2 Documentação de Novos Canais (Priority: LOW)
- [ ] **Atualizar README.md** com novos canais funcionais
- [ ] **Adicionar guias de setup** para cada canal
- [ ] **Adicionar exemplos de uso** no `examples/`

---

## METAS E MILESTONES

### Milestone 1: Canais Básicos (4-6 semanas)
- ✅ Matrix funcional
- ✅ Slack funcional
- ✅ Botões/menus em Telegram/Discord
- ✅ Comandos /help, /start, /status, /model

### Milestone 2: Tools Avançadas (2-3 semanas)
- ✅ Browser tool
- ✅ Process tool
- ✅ Sessions yield

### Milestone 3: UX Completa (3-4 semanas)
- ✅ Threading em todos canais
- ✅ Typing indicators
- ✅ Chunking por limite
- ✅ Loop de tools

### Milestone 4: Canais Restantes (6-8 semanas)
- ✅ WhatsApp
- ✅ Google Chat
- ✅ Lark
- ✅ Mattermost
- ✅ WeChat Work

### Milestone 5: Arquitetura Limpa (2-3 semanas)
- ✅ Port ↔ Adapter wiring
- ✅ Sessão unificada
- ✅ Remoção de todos os TODOs

---

## NOTAS

- **Prioridades podem mudar** conforme necessidade da comunidade
- **Alguns canais (Matrix, Slack) têm maior demanda** que outros
- **Tools de browser são críticas** para agentes que precisam navegar
- **UX interativa é o grande diferencial** vs nullclaw
- **Kernel não precisa de trabalho** - está completo e robusto

---

**Referência:**
- TODO original: `TODO.md`
- Análise de scaffold: ver seção "O que está SCAFFOLDED" em IMPLEMENTATION_ANALYSIS.md
