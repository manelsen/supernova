# Relatório de Análise da Auditoria — Supernova

**Data:** 31/03/2026
**Escopo:** Análise cruzada de `audit/` (recon_deliverable.md, code_analysis_deliverable.md, injection_analysis_deliverable.md, production.md) versus código-fonte real.

---

## 1. Resumo Executivo

A auditoria contém **4 documentos** cobrindo reconhecimento, análise de código, análise de injeção e prontidão para produção. A verificação cruzada contra o código-fonte revela que **a maioria das descobertas procede**, com algumas nuances importantes sobre severidade e alcançabilidade real via rede.

| Categoria | Procede | Parcialmente | Não Procede |
|-----------|---------|--------------|-------------|
| Vulnerabilidades de segurança | 6 | 3 | 0 |
| Problemas de produção (production.md) | 6 | 1 | 0 |
| **Total** | **12** | **4** | **0** |

---

## 2. Achados que PROCEDEM (confirmados no código)

### 2.1 [PROCEDE] SQL Injection em `delete_by_metadata` — Severidade REBAIXADA para LOW

**Audit claim:** SQL injection via `string.replace("$1", key)` em `pgvector.gleam:406`.

**Código real:**
```gleam
let sql =
  "DELETE FROM " <> config.table_name
  <> " WHERE metadata->>'$1' = $2"
  |> string.replace("$1", key)
```

**Verificação:** O código de fato usa `string.replace` para injetar o parâmetro `key` diretamente no SQL, bypassing parametrização. Isso é um defeito real de código.

**Ressalva crítica:** `delete_by_metadata` **não é chamada de nenhum lugar no código de produção**. Nenhum módulo em `src/` invoca essa função — ela existe apenas como API pública não utilizada. O risco é teórico (latente) e não alcançável via rede.

**Veredicto:** Procede como defeito de código. Severidade real: **LOW** (não exploitável atualmente).

---

### 2.2 [PROCEDE] Table name concatenado em SQL — Severidade LOW

**Audit claim:** `config.table_name` é concatenado diretamente em todas as queries SQL.

**Código real:** Confirmado em `insert()`, `similarity_search()`, `delete()`, `delete_by_metadata()`, `ensure_schema()`, `schema_sql()`.

**Ressalva:** `table_name` vem de configuração em código (default: `"embeddings"`, setter via builder `with_table_name`). Não é acessível via input do usuário. Seria necessário comprometer o código-fonte ou arquivo de configuração.

**Veredicto:** Procede como má prática (falta sanitização de identificadores SQL). Risco real: **LOW**.

---

### 2.3 [PROCEDE] Path Traversal em `file_system.gleam` — Severidade MEDIUM

**Audit claim:** `validate_path` só verifica `..`, não bloqueia caminhos absolutos. Não usa `workspace_guard`.

**Código real (file_system.gleam:112-120):**
```gleam
fn validate_path(workspace: String, path: String) -> Result(String, String) {
  case string.contains(path, "..") {
    True -> Error("Path traversal blocked: " <> path)
    False -> { let full_path = workspace <> "/" <> path; Ok(full_path) }
  }
}
```

**workspace_guard.gleam** existe com validação COMPLETA (verifica `..` E caminhos absolutos), mas `file_system.gleam` **não o utiliza**.

**Veredicto:** Procede. O `file_system.gleam` tem validação incompleta. O `workspace_guard.gleam` deveria ser usado, mas não é.

---

### 2.4 [PROCEDE] Browser eval com `globalThis.eval()` — Severidade MEDIUM

**Audit claim:** JavaScript arbitrário executado via `globalThis.eval(script)`.

**Código real (browser_runner.mjs:100-107):**
```javascript
case "evaluate":
  assertString(command.script, "script");
  return {
    value: await withTimeout(
      timeout,
      page.evaluate((script) => globalThis.eval(script), command.script),
    ),
  };
```

**Veredicto:** Procede. Qualquer script chega ao `eval()` sem restrição.

**Nuance de severidade:** O eval ocorre dentro de um contexto de browser Playwright (headless Chromium), não no servidor. O impacto é acesso ao DOM/cookies da página visitada, não RCE no servidor. A severidade é MEDIUM (não CRITICAL como implica a auditoria), pois: (a) requer que o LLM gere a chamada de ferramenta, (b) executa em sandbox do browser, não no host.

---

### 2.5 [PROCEDE] SSRF em `web.gleam` — Severidade MEDIUM

**Audit claim:** Nenhuma validação de URL. Pode acessar IPs internos, metadata endpoints.

**Código real (web.gleam:12-29):** Confirmado. `request.to(url)` verifica apenas sintaxe, sem blocklist de IPs internos, `file://`, ou `169.254.169.254`.

**Nuance:** Requer que o LLM gere a chamada de ferramenta com URL malicioso. É um vetor de ataque indireto (prompt injection → LLM → tool call).

**Veredicto:** Procede. Falta blocklist de IPs internos e validação de scheme.

---

### 2.6 [PROCEDE] SSRF em `browser.gleam` — Severidade MEDIUM

**Audit claim:** `page.goto(url)` sem validação. Pode acessar recursos internos.

**Código real:** Confirmado. A URL é passada diretamente ao Playwright sem filtro.

**Veredicto:** Procede. Mesmo vetor de ataque que 2.5 (via LLM tool call).

---

### 2.7 [PROCEDE] P1 — Slack/Matrix ignorados em produção — Severidade CRITICAL

**Audit claim:** `build_channel_handler` só despacha para Discord e Telegram.

**Código real (supernova.gleam):**
```gleam
fn route_channel_inbound_for_handler(inbound, discord_router, telegram_router, stream_events) {
  case inbound_channel_name(inbound) {
    "discord"  -> discord_router.route_inbound_for_handler(...)
    "telegram" -> telegram_router.route_inbound_for_handler(...)
    channel    -> Error(port.Ignored("channel not configured: " <> channel))
  }
}
```

**Veredicto:** Procede integralmente. Slack, Matrix e demais canais são silenciosamente descartados. A solução proposta em `production.md` é correta e direta.

---

### 2.8 [PROCEDE] P2 — `process.sleep_forever()` impede graceful shutdown — Severidade MEDIUM

**Código real (supernova.gleam):**
```gleam
process.sleep_forever()
// Graceful shutdown (unreachable in normal flow, but here for completeness)
shutdown_services(services)
```

**Veredicto:** Procede. `shutdown_services` é código morto. A solução proposta com signal trapping é adequada.

---

### 2.9 [PROCEDE] P3 — Atores sem supervision tree — Severidade MEDIUM

**Código real:** `metrics`, `tracer`, `circuit_breaker`, `cooldown` — todos iniciados com `let assert Ok(...)` e guardados em globals sem supervisor OTP.

**Veredicto:** Procede. Crash pós-startup resulta em referências órfãs e degradação silenciosa.

---

### 2.10 [PROCEDE] P7 — Uptime calculado incorretamente — Severidade LOW

**Código real:** `handle_health` chama `current_timestamp()` no momento do request em vez de usar `start_time_ms` do `HealthServer`.

**Veredicto:** Procede. O uptime reportado é sempre ~0s.

---

### 2.11 [PROCEDE] P6 — Sem migrations de banco — Severidade LOW-MEDIUM

**Veredicto:** Procede. Não há scripts de migration no repositório. `ensure_schema` no pgvector existe mas precisa de `CREATE EXTENSION vector` prévio.

---

### 2.12 [PROCEDE] Session IDs previsíveis — Severidade LOW

**Código real (session.gleam):**
```gleam
pub fn discord_session_id(channel_id: String, user_id: String) -> String {
  "discord:" <> channel_id <> ":" <> user_id
}
```

**Veredicto:** Procede como observação arquitetural. Porém a severidade real é **LOW** porque: (a) os IDs de sessão são usados internamente entre atores OTP, não como tokens de autenticação HTTP; (b) não existe endpoint HTTP que aceite session ID como parâmetro; (c) a autenticação é delegada às plataformas (Discord, Telegram, etc.).

---

## 3. Achados que PROCEDEM PARCIALMENTE

### 3.1 [PARCIAL] Command Injection via safe_shell — Severidade MEDIUM (não HIGH)

**Audit claim:** `cat /etc/passwd` é permitido. Whitelist bypass via comandos perigosos.

**Código real:** O whitelist (`ls`, `pwd`, `cat`, `head`, `tail`, `find`, `echo`, `date`, `whoami`, `uname`) é real. Operadores perigosos (`;`, `|`, `&&`, etc.) E `..` são bloqueados.

**O que procede:** `cat /etc/passwd` seria bloqueado pelo `..` check? **Não** — `..` só bloqueia path traversal relativo. `cat /etc/passwd` não contém `..`. Porém:
1. O `safe_shell` é chamado via LLM tool dispatch, não diretamente pelo usuário
2. O LLM precisa gerar a tool call — requer prompt injection bem-sucedido
3. O workspace_policy do syscall gateway pode bloquear `OpShell` se configurado

**Severidade real:** MEDIUM. O vetor de ataque é indireto (prompt injection → LLM → tool call).

---

### 3.2 [PARCIAL] MCP STDIO — Comando arbitrário — Severidade NÃO APLICÁVEL

**Audit claim:** Severidade HIGH. Comando arbitrário via `stdio.start(command, args, env)`.

**Código real:** Confirmado que `spawn_executable` é usado (mais seguro que `spawn`). Porém o próprio audit reconhece: **"Not directly reachable via network requests"** e **"Requires local file system access to modify supernova.yaml"**.

**Veredicto:** A vulnerabilidade é real mas está **fora do escopo** de ataque via rede. Requer acesso ao sistema de arquivos para modificar `supernova.yaml`. A classificação HIGH não procede no contexto de pentest de superfície de rede.

---

### 3.3 [PARCIAL] Gateway tool sem validação de path — Severidade CONDICIONAL

**Audit claim:** `gateway.gleam` não valida paths em `read_file`/`write_file`.

**Código real:** Confirmado que `gateway.gleam` não valida. Porém `syscall/actor.gleam` tem validação via `workspace_policy` — **exceto quando nenhuma policy é fornecida** (retorna `Ok(path)` sem validação).

**Veredicto:** A severidade depende da configuração. Com workspace_policy configurada: LOW. Sem policy (usando `start()` em vez de `start_with_policies()`): HIGH.

---

### 3.4 [PARCIAL] P5 — Chrome hardcoded — Severidade LOW

**Audit claim:** Chrome path hardcoded como `/usr/bin/google-chrome`.

**Não verificável diretamente:** O browser_runner.mjs que li usa Playwright's chromium, que resolve o path automaticamente via `chromium.launch()`. O path hardcoded pode existir em outra parte da configuração. A recomendação de torná-lo configurável é boa prática independente.

---

## 4. Achados que NÃO PROCEDEM

**Nenhum achado foi categorizado como completamente falso.** Todas as 9 vulnerabilidades de segurança e 7 problemas de produção têm base factual no código. O que varia é a **severidade real** vs. a severidade reportada.

---

## 5. Reclassificação de Severidades

| ID | Severidade Audit | Severidade Real | Justificativa |
|----|-----------------|-----------------|---------------|
| CMD-001 (safe_shell) | MEDIUM | **MEDIUM** | Mantida — acesso indireto via LLM |
| CMD-002 (MCP stdio) | HIGH | **N/A (fora de escopo)** | Requer acesso local a config |
| LFI-001 (file_system) | MEDIUM | **MEDIUM** | Mantida — path absoluto não bloqueado |
| LFI-002 (gateway) | LOW | **LOW-HIGH (condicional)** | Depende de policy configurada |
| SSTI-001 (browser eval) | HIGH | **MEDIUM** | Sandbox do browser limita impacto |
| SSRF-001 (browser open) | MEDIUM | **MEDIUM** | Mantida |
| SSRF-002 (web fetch) | LOW | **MEDIUM** | Mais exploitável que browser SSRF |
| SQL-001 (table name) | LOW | **LOW** | Mantida — config-only |
| SQL-002 (delete_by_metadata) | — | **LOW** | Função não é chamada em produção |
| P1 (canais ignorados) | CRITICAL | **CRITICAL** | Confirmada |
| P2 (shutdown) | MEDIUM | **MEDIUM** | Confirmada |
| P3 (supervision) | MEDIUM | **MEDIUM** | Confirmada |
| P7 (uptime) | LOW | **LOW** | Confirmada |

---

## 6. Análise de Risco Real (pós-verificação)

### Vetores de ataque alcançáveis via rede:

```
Usuário em plataforma (Discord/Telegram/Slack/Matrix)
  → Mensagem chega ao channel adapter
    → Executor processa via LLM
      → LLM gera tool call
        → Tool executa operação perigosa
```

**Observação fundamental:** TODOS os vetores de segurança identificados dependem de **prompt injection bem-sucedido** contra o LLM para serem explorados. O usuário final não tem acesso direto às ferramentas — ele envia texto que é processado pelo LLM, e o LLM decide quais ferramentas chamar.

Isso **não elimina** o risco (prompt injection é um vetor real e ativo), mas **reduz a severidade efetiva** de todos os achados em comparação com uma API REST onde o atacante controla parâmetros diretamente.

### Risco mais alto (ação imediata):

1. **P1 — Canais ignorados em produção** — Bug funcional, não segurança. Impacto direto na operação.
2. **Path traversal em file_system.gleam** — Mais exploitável via prompt injection por ser operação simples.
3. **SSRF em web.gleam** — Simples de explorar via prompt injection ("busque o conteúdo de http://169.254.169.254/").

### Risco médio (planejamento):

4. **Browser eval** — Requer prompt injection + contexto de browser ativo.
5. **safe_shell com cat** — Bloqueável configurando workspace_policy para negar `OpShell`.
6. **P2/P3** — Resiliência operacional, não segurança.

### Risco baixo (melhoria contínua):

7. **SQL injection latente** — Função não chamada. Corrigir preventivamente.
8. **Session IDs previsíveis** — Sem superfície de ataque HTTP exposta.
9. **Table name em SQL** — Vem de configuração estática.

---

## 7. PRD — Hardening de Segurança e Correções de Produção

### Visão Geral

Consolidação das correções necessárias identificadas pela auditoria, priorizadas por risco real verificado.

---

### REQ-SEC-01: Integrar workspace_guard em file_system.gleam

**Prioridade:** P1 (Alta)
**Tipo:** Bug fix (segurança)

**User Story:** Como operador do Supernova, quero que todas as operações de filesystem usem validação uniforme de paths para evitar acesso a arquivos fora do workspace do agente.

**Critérios de aceite:**
- [ ] `file_system.validate_path()` substituído por chamada a `workspace_guard.validate_path()`
- [ ] Caminhos absolutos (`/etc/passwd`, `/proc/self/environ`) são bloqueados
- [ ] Caminhos com `..` continuam bloqueados
- [ ] Testes existentes continuam passando
- [ ] Novo teste: `file_system.read("workspace", "/etc/passwd")` retorna Error

**Esforço estimado:** P (30 min)

---

### REQ-SEC-02: Blocklist de URLs para web.gleam e browser.gleam

**Prioridade:** P1 (Alta)
**Tipo:** Feature (segurança)

**User Story:** Como operador, quero que ferramentas web não acessem IPs internos, metadata endpoints ou schemes inseguros, para prevenir SSRF.

**Critérios de aceite:**
- [ ] Validação de URL antes de `request.to()` e `page.goto()`
- [ ] Bloqueio de IPs privados: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`
- [ ] Bloqueio de schemes: `file://`, `ftp://`, `gopher://`
- [ ] Apenas `http://` e `https://` permitidos
- [ ] Teste: `web.fetch("http://169.254.169.254/latest/meta-data")` retorna Error
- [ ] Teste: `web.fetch("file:///etc/passwd")` retorna Error

**Esforço estimado:** M (2h)

---

### REQ-SEC-03: Parametrizar key em `delete_by_metadata`

**Prioridade:** P2 (Média)
**Tipo:** Bug fix (segurança preventiva)

**User Story:** Como desenvolvedor, quero que todas as queries SQL usem parametrização completa para evitar injeção.

**Critérios de aceite:**
- [ ] `string.replace("$1", key)` substituído por construção segura (quoting de identificador ou uso de `format()` com validação alphanumeric-only)
- [ ] `table_name` tratado com quoting de identificador (`"` escaping)
- [ ] Teste: `delete_by_metadata(conn, config, "col') OR '1'='1", "val")` não executa SQL injetado

**Nota:** Apesar de não ser chamada em produção hoje, esta função é `pub` e pode ser usada no futuro.

**Esforço estimado:** P (30 min)

---

### REQ-SEC-04: Validação de argumentos de path no safe_shell

**Prioridade:** P2 (Média)
**Tipo:** Enhancement (segurança)

**User Story:** Como operador, quero que comandos whitelisted no safe_shell não possam ler arquivos fora do workspace.

**Critérios de aceite:**
- [ ] Comandos com operação de leitura (`cat`, `head`, `tail`, `find`) têm argumentos de path validados via `workspace_guard`
- [ ] `safe_shell.execute("cat /etc/passwd")` retorna Error
- [ ] `safe_shell.execute("find / -name secret")` retorna Error
- [ ] `safe_shell.execute("cat README.md")` continua funcionando (path relativo ao workspace)

**Esforço estimado:** M (2h)

---

### REQ-PROD-01: Despachar Slack e Matrix no handler de produção

**Prioridade:** P0 (Crítica)
**Tipo:** Bug fix

**User Story:** Como operador, quero que mensagens de Slack e Matrix sejam processadas em produção, não apenas em testes.

**Critérios de aceite:**
- [ ] `build_channel_handler` inicia `slack_router` e `matrix_router`
- [ ] `route_channel_inbound_for_handler` despacha para `"slack"` e `"matrix"`
- [ ] Teste de integração: mensagem Slack chega e é processada
- [ ] Teste de integração: mensagem Matrix chega e é processada
- [ ] Log de warning quando canal não configurado é recebido (em vez de `Ignored` silencioso)

**Esforço estimado:** P (30 min) — módulos já existem

---

### REQ-PROD-02: Graceful shutdown via signal trapping

**Prioridade:** P1 (Alta)
**Tipo:** Bug fix

**User Story:** Como operador, quero que `SIGTERM` acione shutdown graceful para drenar conexões e fechar sessões.

**Critérios de aceite:**
- [ ] `process.sleep_forever()` substituído por mecanismo de signal trapping
- [ ] `shutdown_services()` é executado ao receber `SIGTERM`
- [ ] Docker `stop_grace_period` configurado para 30s
- [ ] Log confirma que shutdown foi executado

**Esforço estimado:** M (2h)

---

### REQ-PROD-03: Supervision tree para atores de infraestrutura

**Prioridade:** P1 (Alta)
**Tipo:** Enhancement

**User Story:** Como operador, quero que crash de atores de infraestrutura (metrics, tracer, circuit breaker, cooldown) resulte em restart automático, não em degradação silenciosa.

**Critérios de aceite:**
- [ ] 4 atores sob supervisor OTP com estratégia `one_for_one`
- [ ] Globals re-registrados após restart do ator
- [ ] Teste: kill do ator metrics resulta em restart automático

**Esforço estimado:** G (3h)

---

### REQ-PROD-04: Health check com dados reais

**Prioridade:** P2 (Média)
**Tipo:** Bug fix

**User Story:** Como operador, quero que `/health` reporte uptime real e `/health/ready` reporte canais efetivamente conectados.

**Critérios de aceite:**
- [ ] `uptime_seconds` calculado a partir de `start_time_ms` do HealthServer
- [ ] `/health/ready` consulta registry para listar canais ativos
- [ ] `channels_ready` não é mais lista vazia hardcoded

**Esforço estimado:** P (1h)

---

### REQ-PROD-05: Migrations de banco de dados

**Prioridade:** P2 (Média)
**Tipo:** Feature

**User Story:** Como operador, quero que um ambiente limpo suba com schema de banco pronto, incluindo extensão pgvector.

**Critérios de aceite:**
- [ ] Script `migrations/init.sql` com `CREATE EXTENSION vector` e tabelas necessárias
- [ ] `docker-compose.yml` monta migration via `docker-entrypoint-initdb.d`
- [ ] Imagem PostgreSQL usa `pgvector/pgvector:pg16`

**Esforço estimado:** M (2h)

---

### Ordem de Implementação Recomendada

| Fase | REQs | Justificativa |
|------|------|---------------|
| **Sprint 1** | REQ-PROD-01, REQ-SEC-01 | Funcionalidade core + fix de segurança mais exploitável |
| **Sprint 2** | REQ-PROD-02, REQ-PROD-03, REQ-SEC-02 | Resiliência + SSRF prevention |
| **Sprint 3** | REQ-PROD-04, REQ-PROD-05, REQ-SEC-03, REQ-SEC-04 | Polish e prevenção |

---

## 8. Conclusão

A auditoria é **tecnicamente sólida**. Os 4 documentos demonstram compreensão profunda da arquitetura do Supernova e identificam vetores de ataque reais. As principais ressalvas são:

1. **Severidades inflacionadas em alguns casos** — a dependência de prompt injection como pré-requisito para exploração reduz a severidade efetiva de vários achados.
2. **Escopo confuso em MCP/config** — achados que requerem acesso local são reportados como se fossem alcançáveis via rede.
3. **SQL injection reportada como exploitável** mas a função `delete_by_metadata` não é chamada de nenhum lugar no código de produção.
4. **production.md é excelente** — diagnósticos precisos com soluções corretas e implementáveis.

O PRD acima consolida as ações necessárias em 9 requisitos priorizados por risco real verificado.
