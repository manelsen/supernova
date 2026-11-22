# Pendências da Supernova

Consolidado em 22/11/2026, a partir de:

- os PRDs do root (`PRD.md`, retomada, B1, B1.1 e rodada 2, B2 e fase C, H, N);
- `docs/prd/production-ready-v1.md` e `tasks/PRDwizard.md`;
- `TODO.md`, `IMPLEMENTATION_TODO.md`, `IMPLEMENTATION_READY.md` e `UX.md`;
- os relatórios em `docs/` (retomada, B1, B1.1, B2, harness);
- `audit/production.md` e `audit/STATUS_2026-11.md`;
- as notas do mantenedor sobre o pós-piloto;
- o que apareceu no piloto e na fase 1 do computador.

Cada item foi conferido no código e, quando possível, no piloto rodando. As caixas dos PRDs são critérios de aceite e nunca foram marcadas, então valem o código e os relatórios, não elas.

Itens sobre Postgres e pgvector foram retirados: o banco saiu na PR #33.

Este documento tem três partes:

1. **Feito**: estava listado como pendente e já está no código.
2. **Incompatível com escolhas posteriores**: precisa ser repensado antes de ser feito.
3. **Em aberto**: para estudar antes de decidir os próximos passos.

---

## 1. Feito

| Item | Onde estava | Onde está |
|---|---|---|
| Comandos `/help`, `/start`, `/status`, `/model` executáveis | `TODO.md` P0, `IMPLEMENTATION_TODO.md` 3.2 | `channel_common_router.gleam`, `core/ux.gleam` |
| Escolha de provedor e modelo por botões, valendo para as mensagens seguintes | `TODO.md` P0, `IMPLEMENTATION_TODO.md` 3.1, `UX.md` C | `build_model_picker` no router; inline keyboard no Telegram, componentes no Discord |
| Sessão por chat com histórico e modelo próprios | `TODO.md` P0 | `session/server.gleam`, trilha única de sessão (US-023) |
| Loop de ferramentas no runtime de canal | `TODO.md` P0, `IMPLEMENTATION_TODO.md` 4.4 | `core/executor.gleam`, usado pela agente no piloto |
| Bootstrap real de canais no `main`, contrato Port ↔ Adapter, resposta rica | `IMPLEMENTATION_TODO.md` P3 | `supernova.gleam`, `channel/registry.gleam`, `channel/port.gleam` |
| Threading, streaming, indicador de digitação, chunking por limite de canal | `IMPLEMENTATION_TODO.md` P2, `IMPLEMENTATION_READY.md` M3 | `channel/registry.gleam`, `channel/chunking.gleam` |
| Adaptadores nativos: Slack, Matrix, WhatsApp, Lark, Google Chat, Mattermost, WeChat Work | `IMPLEMENTATION_TODO.md` P0 | `adapters/*`; a orquestração continua genérica (ver 3.2) |
| Ferramentas browser, process, github, canvas, gateway (os stubs saíram) | `IMPLEMENTATION_TODO.md` P1 | `tools/`; nenhum `not implemented` restante |
| Health checks `/health`, `/health/live`, `/health/ready` | `production-ready-v1` REQ-2 | `health/server.gleam`; os três respondem no piloto |
| Circuit breaker, cooldown de failover, retry com backoff | `production-ready-v1` REQ-5/6/7, 13/14/15 | `llm/` |
| Fim do fallback silencioso para mock (`mock` só quando configurado) | `production-ready-v1` REQ-1 | `llm/client.gleam` |
| Deploy com um comando | `production-ready-v1` REQ-10 | `docker compose up -d` |
| Sub-agentes em paralelo | `production-ready-v1` REQ-16 | `core/sub_agent.gleam` |
| Conteúdo do mantenedor: constelação, prompts de nascimento, nome, reflexão e drift | Relatório B2 | `priv/constellation/`, `priv/reflection/` |
| Agente sabe que, no grupo, só vê a própria pessoa | Propostas do harness, 1 | `priv/constellation/agent_guidance.md` |
| Recusar com ironia conta como manter a voz | Propostas do harness, 2 | `priv/harness/rubrics/ferramentas_self.md` C3 |
| Agente entende o nome que recebe | PRD N | `priv/constellation/name_prompt.md` e fluxo de nome |
| Personas `bia`, `caio` e rubrica `provisorio` | Relatório H | Marcadas como provisórias de propósito: são fixtures dos testes do executor, não conteúdo real |
| Computador da agente, fase 1: gVisor, shell, browser, visão | — | PR #34, `docs/operations/COMPUTADOR.md` |
| Firewall do computador e rota da Supernova pela própria rede | — | PR #35; regras aplicadas e conferidas no host |

---

## 2. Incompatível com escolhas posteriores

### 2.1 Quickstart nativo com `curl` + `systemd` (`tasks/PRDwizard.md`)

O PRD tira o Docker do caminho principal e instala o serviço direto no host, com `systemd`. Hoje a Supernova roda em Docker e o computador da agente depende de Docker com gVisor (`runsc`).

**O que se aproveita, adaptado ao Docker com gVisor:**

- o wizard obrigatório antes da primeira subida, gerando `supernova.yaml` e `.env`;
- o modo não interativo, equivalente ao wizard, para automação e CI;
- a separação entre configuração estrutural (`supernova.yaml`) e segredos (`.env`, modo 600);
- o resumo com confirmação explícita antes do primeiro `docker compose up`;
- a detecção do ambiente: Docker e Compose (≥ 2.33.1, por causa do `gw_priority`), `runsc` registrado, KVM opcional;
- os passos que hoje são manuais e dependem de `sudo`: instalar o gVisor e as regras de firewall do computador;
- o smoke test do quickstart e a verificação de que os comandos da documentação existem.

**O que não se aproveita:** o serviço instalado direto no host com `systemd`, o Docker relegado a "dev/advanced" e o release BEAM pré-compilado como caminho principal.

### 2.2 Onboarding antigo e "bootstrap de agente por sessão"

O `/start` com onboarding e a criação de uma agente por sessão (`TODO.md` P0, `UX.md` D) foram substituídos pelo nascimento da B2: uma agente por pessoa, com núcleo e nome. No modo grupo fechado, `/start` e `/reset-identity` são recusados depois do nome.

**O que estudar:** se o onboarding antigo ainda serve para o modo aberto, ou se o modo aberto deve nascer como a B2.

---

## 3. Em aberto

### 3.1 Conversa e memória

- **O histórico da conversa se perde quando a Supernova reinicia.**
  - **Situação:** o `session/server` guarda o histórico só em memória. O reinício de 22/11 às 09:37 apagou a conversa da madrugada. Lembranças, diário, experiência, arquivos e agenda sobrevivem.
  - **Origem:** `audit/production.md` ("Reinício do container preserva histórico de sessão").
  - **Para estudar:** onde guardar (arquivo por agente, como o resto do `self/`?); quanto guardar; como o `/esquecer` apaga esse histórico.
- **A mudança lenta não dispara com uma pessoa só.**
  - **Situação:** com reflexão semanal de força 0,25, a pressão efetiva máxima em um ano é 0,38, para um limiar de 3,0. Pessoas diferentes somam sem desconto, então na prática só várias pessoas juntas mudam a agente.
  - **Para estudar:** a intenção é "uma pessoa sozinha nunca muda a agente" (e então está funcionando) ou "meses de convivência mudam devagar" (e então o limiar ou o desconto precisam de recalibração)?
- **Grupo em que todas as agentes veem o grupo.** O piloto seguiu com cada agente vendo só a própria pessoa (decisão de 20/11). Antes de fazer, decidir:
  - o `/esquecer` no grupo;
  - a fronteira entre o que é do grupo e o que é privado;
  - a insistência que vem de outras pessoas;
  - a triangulação;
  - o custo por tamanho de grupo;
  - o consentimento do grupo.
- **Pedido natural de esquecer e acolhimento.** Numa bateria de 3 execuções, uma agente julgou a pessoa ("da mesma laia"). Falta uma bateria maior para saber se é recorrente.
- **A agente inventa explicações quando é pega num erro.** No piloto, em 22/11, ela disse que uma resposta "não existe mais neste histórico — mas eu me lembro", e a resposta estava no contexto. Também anunciou como feito o que era intenção ("já existe o caderno"). Vale um cenário de harness para isso.

### 3.2 Canais

- **A pessoa não consegue mandar imagens, áudio nem documentos.** O Telegram ignora `photo` na entrada, e no Discord os `attachments` chegam sempre vazios. O caminho de imagem até o modelo já existe, desde a PR #34.
- **O grupo fechado só existe em Telegram e Discord.**
  - Os outros sete canais têm adaptador nativo, mas a orquestração passa pelo `generic_channel_router`, sem o pipeline de acesso e orçamento e sem testes de ponta a ponta. Por isso são "experimentais".
  - Origem: `TODO.md` P1.
- **Slack e Matrix sem paridade com Telegram e Discord.** Faltam sessão, comandos, interações e testes de ponta a ponta. Origem: `TODO.md`, pós-PRD.
- **Nunca testados com mensagem real:** Slack e Matrix. Origem: `audit/production.md`.
- **QQ nunca foi feito.** Origem: `IMPLEMENTATION_READY.md` 4.6.
- **Matrix:** o limite de tamanho não é verificado nas edições. Origem: relatório B1.1.
- **Discord:** um `retry_after` abaixo de um segundo é truncado para segundos. Origem: relatório B1.1.

### 3.3 Interação e computador

- **Interface de aprovação.** Botões de aprovar ou recusar antes de uma ação, com o ciclo de vida no Port. Origem: `UX.md` 4.
- **Computador, fase 2.** Encaixa com a interface de aprovação.
  - um computador por pessoa, apagado no `/esquecer`;
  - uma tela que a pessoa pode assumir (noVNC) para login e captcha;
  - confirmação garantida pelo código antes de qualquer efeito fora da máquina;
  - tarefas longas assíncronas.
- **Yield manual de sessão.** O checkpoint por orçamento e por tempo existe no executor. Uma ferramenta para a agente ceder a vez por conta própria nunca foi exposta. Origem: `IMPLEMENTATION_TODO.md` 2.5.

### 3.4 Observabilidade e desempenho

- **Métricas** (`production-ready-v1` REQ-4/11). O `/metrics` existe e responde 200, mas vem vazio no piloto: só o código de sub-agentes registra métricas, e a conversa, as ferramentas e as chamadas de LLM não registram nada.
- **Tracing** (REQ-3/12). Não existe. A dependência `opentelemetry_api` saiu junto com o driver do Postgres.
- **Benchmarks** (REQ-9). O código está em `test/bench/`, mas as metas de `BENCHMARKS.md` nunca foram medidas.
- **Teste de carga** (REQ-8). O código está em `tests/load/` e `run_load_tests.sh`. A meta (100 usuários, p99 < 2 s, erro < 1%) nunca foi verificada.
- **Verificação final da v1.** Faltam os critérios de `production-ready-v1`: spans visíveis, circuit breaker medido e nenhum `mock` em código de produção.

### 3.5 Qualidade

- **Cobertura de 85%.** O gate está em 75%. Origem: retomada.
- **Testes com Chromium real no CI.** Hoje só rodam com `SUPERNOVA_BROWSER_TESTS=1`. O computador já roda os testes dele no CI. Origem: auditoria 3.4.

### 3.6 Documentação

- **`README.md`** ainda apresenta a v0.3.0 com Postgres. Falta contar a agente companheira, uma agente por pessoa e o computador.
- **`STATUS.md`** parou em 18/11: tem números antigos e lista o Postgres como persistência.
- **`OBSERVABILITY.md`** diz que o `/metrics` "não está integrado" e que o `/ready` checa banco. Os alertas descrevem métricas que nunca são registradas.
- **`BENCHMARKS.md`** é só "TBD".
- **O PRD N não tem relatório.**
- **A raiz está bagunçada.** Falta mover PRDs, notas de versão e planos antigos para `docs/` e revisar `docs/rag/` e `docs/research/`.

### 3.7 Riscos aceitos (revisitar)

Riscos aceitos nos relatórios, mantidos aqui para não se perderem.

**Fila e reinício**

- A fila não é durável: um kill forçado perde as mensagens que ainda não começaram.
- O uso perdido depois de três tentativas é auditado, mas não entra no total do dia.

**Orçamento e reservas**

- Uma resposta acima da reserva de saída pode passar do teto numa única chamada.
- Uma chamada de LLM com mais de 10 minutos libera a reserva antes de terminar.
- O TTL das reservas usa o relógio de parede, não um relógio monotônico.
- Reduzir o teto não invalida as reservas já abertas.
- Os IDs de chamada legados não sobrevivem a um reinício.
- O estorno usa buckets de hora de parede; um cancelamento na virada do dia pode não ser estornado.

**Agente e memória**

- O `/esquecer` não é transacional e não cancela um turno ou uma reflexão já em andamento.
- Uma trava órfã da reflexão exige remoção manual.
- O drift não valida o tamanho de 40 a 120 palavras do acréscimo.
- No modo aberto, o workspace do router e o da política continuam divergentes.

**Outros**

- Os IDs internos de sessão são determinísticos. Não há endpoint exposto e a autenticação fica com as plataformas.
- O MCP por stdio executa um comando vindo da configuração local.
- Uma revogação feita antes da migração do `access.json` legado pode reaparecer.
