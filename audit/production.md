# Supernova — Relatório de Prontidão para Produção

**Data:** 31/03/2026  
**Snapshot analisado:** `supernova-31_03_2026.txt`  
**PRD:** 29 user stories, todas `passes: true`  
**Testes:** `1640 passed, no failures` (`gleam test`)  

---

## Sumário Executivo

O projeto está **funcionalmente completo a nível de testes**, mas **não está pronto para produção**. Há um bug de integração crítico que silencia metade dos canais implementados no binário real, e três problemas de grau médio que comprometem operação robusta. Os problemas são cirúrgicos — nenhum exige reescrita; todos têm solução direta.

---

## Critérios de Avaliação

| Critério                               | Status |
| -------------------------------------- | ------ |
| Correção (testes passam)               | ✅      |
| Completude do PRD (ponta a ponta)      | ❌      |
| Segurança operacional (crash recovery) | ⚠️      |
| Deployabilidade (containerização)      | ⚠️      |
| Observabilidade (health, métricas)     | ⚠️      |
| Migrations de banco                    | ❌      |

---

## Problemas e Soluções

---

### P1 — Slack, Matrix e demais canais são silenciosamente ignorados em produção

**Severidade:** 🔴 Crítico  
**Arquivo:** `src/supernova.gleam`, função `build_channel_handler`

#### Diagnóstico

O `new_channel_router_test.gleam` usa um handler com quatro routers (Discord, Telegram, Slack, Matrix). O `supernova.gleam` de produção usa apenas dois:

```gleam
// supernova.gleam — estado atual
fn route_channel_inbound_for_handler(inbound, discord_router, telegram_router, stream_events) {
  case inbound_channel_name(inbound) {
    "discord"  -> discord_router.route_inbound_for_handler(...)
    "telegram" -> telegram_router.route_inbound_for_handler(...)
    channel    -> Error(port.Ignored("channel not configured: " <> channel))
    //                  ↑ Slack, Matrix, WhatsApp, Lark, etc. chegam aqui
  }
}
```

O registry inicia os adapters de Slack, Matrix, etc. corretamente. Eles se conectam. Mensagens chegam. O registry chama o handler. O handler retorna `Ignored`. Sem erro, sem log de aviso, sem resposta ao usuário. A falha é invisível.

A razão pela qual os testes de US-028/029 passam: eles testam o registry com um handler construído internamente ao test helper `runtime_handler_with_supervisor`, que já inclui os quatro routers. O binário de produção usa um handler diferente.

#### Solução

Estender `build_channel_handler` para iniciar e despachar Slack e Matrix, seguindo o padrão já existente nos testes. Os módulos `slack_router` e `matrix_router` já expõem `start_with_session_supervisor` e `route_inbound_for_handler` — a API está pronta.

```gleam
// supernova.gleam — após a correção

import supernova/adapters/matrix_router
import supernova/adapters/slack_router

fn build_channel_handler(
  cfg: config.Config,
  session_supervisor: supervisor.SessionSupervisor,
) -> Result(port.ChannelHandler, String) {
  use llm_config <- result.try(default_channel_llm_config(cfg))

  use discord_channel_router <- result.try(
    discord_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Discord channel router" }),
  )
  use telegram_channel_router <- result.try(
    telegram_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Telegram channel router" }),
  )
  use slack_channel_router <- result.try(
    slack_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Slack channel router" }),
  )
  use matrix_channel_router <- result.try(
    matrix_router.start_with_session_supervisor(session_supervisor, llm_config)
    |> result.map_error(fn(_) { "Failed to start Matrix channel router" }),
  )

  Ok(fn(inbound, stream_events) {
    route_channel_inbound_for_handler(
      inbound,
      discord_channel_router,
      telegram_channel_router,
      slack_channel_router,
      matrix_channel_router,
      stream_events,
    )
  })
}

fn route_channel_inbound_for_handler(
  inbound: port.ChannelInbound,
  discord_channel_router: discord_router.DiscordRouter,
  telegram_channel_router: telegram_router.TelegramRouter,
  slack_channel_router: slack_router.SlackRouter,
  matrix_channel_router: matrix_router.MatrixRouter,
  stream_events: process.Subject(port.ChannelStreamEvent),
) -> Result(port.ChannelHandlerResult, port.ChannelError) {
  case inbound_channel_name(inbound) {
    "discord" ->
      discord_router.route_inbound_for_handler(
        discord_channel_router, inbound, stream_events,
      )
    "telegram" ->
      telegram_router.route_inbound_for_handler(
        telegram_channel_router, inbound, stream_events,
      )
    "slack" ->
      slack_router.route_inbound_for_handler(
        slack_channel_router, inbound, stream_events,
      )
    "matrix" ->
      matrix_router.route_inbound_for_handler(
        matrix_channel_router, inbound, stream_events,
      )
    channel -> Error(port.Ignored("channel not configured: " <> channel))
  }
}
```

**Nota sobre WhatsApp, Lark, Google Chat, Mattermost, WeChat Work:** esses adapters têm apenas `send` (sem `route_inbound_for_handler`). O inbound deles chega via webhook HTTP externo, não pelo handler do registry. Estão fora do escopo desta correção, mas precisam de documentação clara sobre como o inbound é roteado para eles.

---

### P2 — Graceful shutdown é inalcançável

**Severidade:** 🟡 Médio  
**Arquivo:** `src/supernova.gleam`, função `main`

#### Diagnóstico

```gleam
process.sleep_forever()     // bloqueia indefinidamente
shutdown_services(services) // nunca executa
```

No BEAM, `process.sleep_forever()` é um receive sem mensagem de saída. O processo principal dorme para sempre e é morto pelo SO via SIGTERM sem executar nenhum cleanup. Channels não são drenados, sessões não são fechadas, MCP servers não são encerrados graciosamente.

Em Docker, o container recebe `SIGTERM` e aguarda `stop_grace_period` (padrão: 10s) antes de `SIGKILL`. Nada do cleanup ocorre nesse intervalo.

#### Solução

Usar o mecanismo de signal trapping do Erlang para capturar SIGTERM e acionar o shutdown:

```gleam
// supernova.gleam — após a correção
import gleam/erlang

fn await_shutdown_signal() -> Nil {
  // Registra o processo principal como handler de sistema
  erlang.set_process_flag(erlang.TrapExit, True)
  // Recebe qualquer mensagem — na prática, EXIT do sistema operacional
  // propagado pelo BEAM como exit signal ao processo principal
  let shutdown_subject = process.new_subject()
  let _ = process.receive(shutdown_subject, 0)
  process.sleep_forever()
}
```

Uma abordagem mais idiomática em Gleam/OTP: usar `gleam_otp`'s `actor` supervisioned shutdown via `:init.stop()`. O padrão mais direto disponível sem FFI adicional é registrar o processo principal como receptor de sinais via `erlang:process_flag(trap_exit, true)` e usar um `receive` com timeout:

```erlang
%% supernova_signal_ffi.erl — novo arquivo FFI
-module(supernova_signal_ffi).
-export([wait_for_shutdown/0]).

wait_for_shutdown() ->
    process:flag(trap_exit, true),
    receive
        {'EXIT', _, shutdown} -> ok;
        {'EXIT', _, _}        -> ok
    end.
```

```gleam
// supernova.gleam
@external(erlang, "supernova_signal_ffi", "wait_for_shutdown")
fn wait_for_shutdown() -> Nil

// Em main(), substituir:
//   process.sleep_forever()
//   shutdown_services(services)
// Por:
wait_for_shutdown()
shutdown_services(services)
```

Para Docker, adicionar ao `docker-compose.yml`:

```yaml
supernova:
  stop_grace_period: 30s  # tempo para o cleanup completar
```

---

### P3 — Atores críticos inicializados sem supervision tree

**Severidade:** 🟡 Médio  
**Arquivo:** `src/supernova.gleam`, função `start_services`

#### Diagnóstico

Quatro atores são iniciados com `let assert Ok(...)` e registrados em globais (ETS/process registry), mas não há nenhum supervisor OTP cobrindo eles:

```gleam
let assert Ok(metrics)  = metrics_actor.start()
metrics_global.set_metrics(metrics)

let assert Ok(tracer)   = tracing_actor.start(tracer_config)
tracing_global.set_tracer(tracer)

let assert Ok(cb)       = cb_actor.start(cb_config)
cb_global.set_circuit_breaker(cb)

let assert Ok(cooldown) = cd_actor.start(cd_config)
cd_global.set_cooldown(cooldown)
```

Se qualquer um desses atores crashar após o startup (por um bug, OOM, etc.), a referência global aponta para um processo morto. O próximo acesso provavelmente crashará o processo chamador, propagando a falha para cima. Sem supervisor para reiniciá-los, o sistema degrada silenciosamente.

#### Solução

Colocar esses quatro atores sob um supervisor OTP com estratégia `one_for_one`. Em Gleam/OTP, isso é feito via `gleam_otp`'s `supervisor`:

```gleam
import gleam/otp/supervisor

fn start_infrastructure_supervisor() -> Result(supervisor.Supervisor, String) {
  supervisor.start(fn(children) {
    children
    |> supervisor.add(supervisor.worker(fn() {
      use metrics <- result.try(
        metrics_actor.start()
        |> result.map_error(fn(_) { actor.InitFailed }),
      )
      metrics_global.set_metrics(metrics)
      Ok(metrics)
    }))
    |> supervisor.add(supervisor.worker(fn() {
      use tracer <- result.try(
        tracing_actor.start(tracer_config)
        |> result.map_error(fn(_) { actor.InitFailed }),
      )
      tracing_global.set_tracer(tracer)
      Ok(tracer)
    }))
    // ... circuit breaker, cooldown
  })
  |> result.map_error(fn(_) { "Failed to start infrastructure supervisor" })
}
```

**Alternativa de curto prazo** (sem refatoração estrutural): monitorar os processos do processo principal e reiniciá-los manualmente se saírem:

```gleam
process.monitor_process(process.subject_owner(metrics_subject))
```

A solução com supervisor OTP é a correta a longo prazo.

---

### P4 — Dockerfile ausente do snapshot / não verificado

**Severidade:** 🟡 Médio  
**Arquivo:** `Dockerfile` (listado no diretório, mas sem conteúdo no dump)

#### Diagnóstico

O `docker-compose.yml` usa `build: .`, indicando que deve existir um `Dockerfile` na raiz. O arquivo aparece na árvore de diretórios do projeto mas seu conteúdo **não está presente no snapshot** `supernova-31_03_2026.txt`. Pode ser:

- Um arquivo real que simplesmente não foi incluído no dump (mais provável)
- Um arquivo ausente que bloqueia `docker compose up`

#### Solução

**Verificar imediatamente:** `ls -la Dockerfile && docker compose build` no repositório real.

Se ausente, criar um Dockerfile mínimo adequado para Gleam/BEAM. Gleam compila para Erlang, então a imagem de runtime é a Erlang base:

```dockerfile
# Dockerfile
FROM erlang:27-alpine AS builder

RUN apk add --no-cache curl git nodejs npm

# Instalar Gleam
RUN curl -L https://github.com/gleam-lang/gleam/releases/latest/download/gleam-linux-amd64.tar.gz \
    | tar xz -C /usr/local/bin

WORKDIR /app
COPY gleam.toml manifest.toml ./
COPY src/ src/

RUN gleam build --target erlang

# Runtime stage
FROM erlang:27-alpine

# Browser tool precisa de Chromium (ver P5)
RUN apk add --no-cache chromium chromium-chromedriver nodejs npm

WORKDIR /app
COPY --from=builder /app/build/erlang-shipment ./build/erlang-shipment
COPY examples/quickstart/supernova.yaml ./supernova.yaml

CMD ["./build/erlang-shipment/entrypoint.sh", "run"]
```

**Nota:** o `gleam export erlang-shipment` gera um diretório autocontido para deploy. Verificar se o projeto já usa esse mecanismo.

---

### P5 — Browser tool com Chrome hardcoded e sem fallback

**Severidade:** 🟡 Médio  
**Arquivo:** `scripts/browser_runner.mjs`, `src/supernova_browser_ffi.erl`

#### Diagnóstico

O browser tool usa `/usr/bin/google-chrome` fixo no código. Em ambientes sem Chrome nesse path exato (Alpine Linux usa `/usr/bin/chromium`, Ubuntu usa `/usr/bin/google-chrome` ou `/usr/bin/chromium-browser`, etc.), o tool falha silenciosamente ou com erro de spawn não tratado.

```javascript
// browser_runner.mjs — estado atual (inferido da arquitetura)
const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome' });
```

Adicionalmente, o health check em `/health/ready` não reflete se o Chrome está disponível.

#### Solução

**1. Tornar o path configurável:**

```yaml
# supernova.yaml
tools:
  browser:
    enabled: true
    chrome_executable: "${SUPERNOVA_CHROME_EXECUTABLE:-/usr/bin/chromium}"
```

**2. Verificar disponibilidade no startup e logar estado claro:**

```gleam
// supernova.gleam — em start_services
let browser_available = check_browser_available(cfg.tools.browser)
case browser_available {
  True  -> io.println("✓ Browser tool available")
  False -> io.println("⚠ Browser tool disabled: Chrome not found at configured path")
}
```

**3. No `browser_runner.mjs`, usar variável de ambiente com fallback:**

```javascript
const executablePath =
  process.env.SUPERNOVA_CHROME_EXECUTABLE ||
  '/usr/bin/chromium' ||
  '/usr/bin/google-chrome';
```

**4. No Dockerfile**, usar Chromium (disponível em Alpine) em vez de Google Chrome:

```dockerfile
RUN apk add --no-cache chromium
ENV SUPERNOVA_CHROME_EXECUTABLE=/usr/bin/chromium
```

---

### P6 — Sem migrations de banco de dados

**Severidade:** 🟡 Baixo-Médio  
**Contexto:** `docker-compose.yml` configura PostgreSQL; `src/supernova/adapters/pgvector.gleam` existe

#### Diagnóstico

O postgres é iniciado via Docker Compose mas não há scripts de migration visíveis no projeto. O `pgvector.gleam` sugere uso de extensão `pgvector` para memória vetorial. Sem migrations:

- A extensão `pgvector` não é criada automaticamente
- Tabelas de sessão/memória não existem ao iniciar o container em ambiente limpo
- Falhas de banco são silenciosas até o primeiro uso

#### Solução

**Curto prazo:** adicionar script de inicialização ao PostgreSQL via `docker-compose.yml`:

```yaml
postgres:
  image: pgvector/pgvector:pg16  # imagem com extensão já instalada
  volumes:
    - postgres_data:/var/lib/postgresql/data
    - ./migrations/init.sql:/docker-entrypoint-initdb.d/01-init.sql
```

```sql
-- migrations/init.sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  channel TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  history JSONB DEFAULT '[]',
  provider_config JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS memory_entries (
  id BIGSERIAL PRIMARY KEY,
  session_id TEXT REFERENCES sessions(id),
  embedding vector(1536),
  content TEXT NOT NULL,
  metadata JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS memory_embedding_idx
  ON memory_entries USING ivfflat (embedding vector_cosine_ops);
```

**Longo prazo:** adotar uma ferramenta de migration (ex: `dbmate`, `flyway`) e adicionar ao pipeline de CI/CD.

---

### P7 — Health check `/health/ready` não reflete estado real

**Severidade:** 🟢 Baixo  
**Arquivo:** `src/supernova/health/server.gleam`

#### Diagnóstico

Dois problemas no health check:

**1. Uptime incorreto:** `uptime_seconds` é calculado com o timestamp do momento do request, não do startup:

```gleam
fn handle_health(req) {
  let start_ms = current_timestamp()  // ← errado: é o momento do request, não o startup
  let status = health_types.HealthStatus(
    uptime_seconds: uptime_seconds(start_ms),  // sempre 0
    ...
  )
}
```

O `HealthServer` já armazena `start_time_ms` mas `handle_health` não tem acesso a ele. O handler precisa receber o `HealthServer` (ou ao menos o `start_time_ms`) como argumento de closure.

**2. `channels_ready` hardcoded como lista vazia:**

```gleam
ReadinessStatus(channels_ready: [])  // nunca reflete estado real
```

O `/health/ready` reporta sempre `ok` independente de nenhum canal ter conectado.

#### Solução

Passar `start_time_ms` para o handler via closure e injetar o estado real do registry:

```gleam
pub fn start(
  port: Int,
  metrics: metrics_actor.Metrics,
  get_ready_channels: fn() -> List(String),  // callback injetado
) -> HealthServer {
  let start_time_ms = current_timestamp()

  let assert Ok(_) =
    fn(req) { handle_request(req, metrics, start_time_ms, get_ready_channels) }
    |> mist.new
    |> mist.port(port)
    |> mist.start

  HealthServer(start_time_ms: start_time_ms, port: port, metrics: metrics)
}
```

No `supernova.gleam`, passar um callback que consulta o registry:

```gleam
let get_ready_channels = fn() { dict.keys(channel_reg.channels) }
let health_srv = health_server.start(health_port, metrics, get_ready_channels)
```

---

## Plano de Ação

Ordered por impacto/esforço:

| Prioridade | Problema                          | Esforço estimado | Desbloqueio                       |
| ---------- | --------------------------------- | ---------------- | --------------------------------- |
| 1          | P1 — Canais ignorados em produção | ~30 min          | Slack/Matrix funcionando          |
| 2          | P4 — Verificar/criar Dockerfile   | ~1h              | Deploy viável                     |
| 3          | P6 — Migrations de banco          | ~2h              | Ambiente limpo funcional          |
| 4          | P2 — Graceful shutdown            | ~2h              | Deploys sem perda de estado       |
| 5 —        | P3 — Supervision tree             | ~3h              | Resiliência a crashes pós-startup |
| 6          | P5 — Chrome configurável          | ~1h              | Browser tool portável             |
| 7          | P7 — Health check preciso         | ~1h              | Observabilidade real              |

P1 é o único que transforma o estado atual de "parcialmente funcional em testes" para "completo em produção". Os demais aumentam robustez e operabilidade, mas não adicionam funcionalidade.

---

## Checklist de Pré-Deploy

Após as correções:

- [ ] `gleam build && gleam test` passam
- [ ] `docker compose build` completa sem erro
- [ ] `docker compose up` sobe sem erro
- [ ] `curl localhost:8080/health/ready` retorna canais habilitados
- [ ] Mensagem via Telegram recebe resposta
- [ ] Mensagem via Slack recebe resposta
- [ ] Mensagem via Matrix recebe resposta
- [ ] `docker compose stop` aguarda cleanup (verificar logs de shutdown)
- [ ] Reinício do container preserva histórico de sessão
