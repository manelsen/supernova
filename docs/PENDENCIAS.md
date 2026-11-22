# Pendências da Supernova

Consolidado em 22/11/2026, a partir de:

- os PRDs, hoje em [`docs/prd/`](prd/);
- os relatórios, em [`docs/relatorios/`](relatorios/);
- os planos de março (`TODO.md`, `IMPLEMENTATION_TODO.md`, `IMPLEMENTATION_READY.md`, `UX.md`), hoje em [`docs/arquivo/`](arquivo/);
- `audit/production.md` e `audit/STATUS_2026-11.md`;
- as notas do mantenedor sobre o pós-piloto;
- o que apareceu no piloto e na fase 1 do computador.

Cada item foi conferido no código e, quando possível, no piloto rodando. As caixas dos PRDs são critérios de aceite e nunca foram marcadas, então valem o código e os relatórios, não elas.

Itens sobre Postgres e pgvector foram retirados: o banco saiu na PR #33.

Este documento tem quatro partes:

0. **Decisões e prioridades**: o que o mantenedor decidiu em 22/11 e em que ordem.
1. **Feito**: estava listado como pendente e já está no código.
2. **Incompatível com escolhas posteriores**: precisa ser repensado antes de ser feito.
3. **Pendências por tema**: cada uma com a decisão que recebeu.

---

## 0. Decisões e prioridades (22/11)

Ordem de trabalho:

1. **Documentação (nível 1).** Resolvida antes de qualquer outro ponto, incluindo a atualização dos PRDs em disco (3.6).
2. **Qualidade, no topo** (3.5).
3. **Observabilidade total**: o que não pode ser medido dificilmente melhora e frequentemente regride (3.4).
4. Os demais temas, em ordem a combinar: conversa e memória (3.1), Discord (3.2), aprovação e computador fase 2 (3.3), wizard (2.1).

Decisões por tema:

| Tema | Decisão |
|---|---|
| Histórico da conversa | Precisa ser preservado entre reinícios, junto com a fila de mensagens (sai dos riscos aceitos). |
| Mudança lenta | Deve disparar com uma pessoa só depois de uma semana de encorajamento. |
| O que a agente vê no grupo | Todas as mensagens da sua pessoa **e** todas as mensagens em que ela for mencionada explicitamente (@). |
| Explicações inventadas | Aprimorar o prompt para checar esse tipo de alucinação. |
| Canais | O Discord ganha paridade com o Telegram. Os demais canais esperam a vez. |
| Aprovação | Botões de aprovação, **sem** liberação geral (nada de "aprovar tudo"). |
| Computador | Pode passar à fase 2. |
| Observabilidade | Total. |
| Qualidade | No topo. |
| Documentação | Atualizar tudo; nível 1. |
| Wizard | Boa ideia, adaptada ao fluxo com Docker e gVisor. |
| Riscos aceitos | Continuam aceitos; podem ser revistos com bons argumentos. |
| `docs/rag` e material de referência antigo | Limpar o que ficou para trás. |

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
| Circuit breaker e retry com backoff | `production-ready-v1` REQ-5/6/7, 13/14/15 | `llm/`. O breaker só bloqueava uma vez: a passagem de aberto para meio-aberto não era gravada, e depois dos primeiros 30 s ele liberava tudo para sempre. Corrigido e coberto pelo ciclo completo em `test/llm/circuit_breaker_cycle_test.gleam`. |
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
| Boot recusa provedor sem chave | Revisão da #37 | `config.selected_provider`; a mensagem diz qual variável definir |
| `/health/ready` com estado real: 503 quando um canal não está pronto; Telegram acompanhado a cada poll, com backoff nos erros | `production-ready-v1` REQ-2, auditoria P7 | `channel/health.gleam`; os outros canais seguem em 3.4 |
| `/agenda` funciona com o teto estourado, como `/esquecer` | Revisão da #37 | `core/closed_group/runtime.gleam` |

---

## 2. Incompatível com escolhas posteriores

### 2.1 Quickstart nativo com `curl` + `systemd` ([`docs/prd/PRD-wizard.md`](prd/PRD-wizard.md))

O PRD tira o Docker do caminho principal e instala o serviço direto no host, com `systemd`. Hoje a Supernova roda em Docker e o computador da agente depende de Docker com gVisor (`runsc`).

**O que se aproveita, adaptado ao Docker com gVisor:**

- o wizard obrigatório antes da primeira subida, gerando `supernova.yaml` e `.env`;
- o modo não interativo, equivalente ao wizard, para automação e CI;
- a separação entre configuração estrutural (`supernova.yaml`) e segredos (`.env`, modo 600);
- o resumo com confirmação explícita antes do primeiro `docker compose up`;
- a detecção do ambiente: Docker e Compose (≥ 2.33.1, por causa do `gw_priority`), `runsc` registrado, KVM opcional;
- os passos que hoje são manuais e dependem de `sudo`: instalar o gVisor e as regras de firewall do computador;
- o smoke test do quickstart e a verificação de que os comandos da documentação existem.

**Ponto de partida:** o CLI em `scripts/quickstart/supernova` (instalar, configurar pelo wizard em container, subir, logs, `doctor`) e a documentação dele, arquivada em `docs/arquivo/onboarding-cli/`. Ele ainda não conhece o gVisor nem o computador, e a imagem que ele baixa só é publicada em tags.

**O que não se aproveita:** o serviço instalado direto no host com `systemd`, o Docker relegado a "dev/advanced" e o release BEAM pré-compilado como caminho principal.

### 2.2 Onboarding antigo e "bootstrap de agente por sessão"

O `/start` com onboarding e a criação de uma agente por sessão (`TODO.md` P0, `UX.md` D) foram substituídos pelo nascimento da B2: uma agente por pessoa, com núcleo e nome. No modo grupo fechado, `/start` e `/reset-identity` são recusados depois do nome.

**O que estudar:** se o onboarding antigo ainda serve para o modo aberto, ou se o modo aberto deve nascer como a B2.

---

## 3. Pendências por tema

### 3.1 Conversa e memória

- **O histórico da conversa se perde quando a Supernova reinicia.**
  - **Situação:** o `session/server` guarda o histórico só em memória. O reinício de 22/11 às 09:37 apagou a conversa da madrugada. Lembranças, diário, experiência, arquivos e agenda sobrevivem.
  - **Origem:** `audit/production.md` ("Reinício do container preserva histórico de sessão").
  - **Para estudar:** onde guardar (arquivo por agente, como o resto do `self/`?); quanto guardar; como o `/esquecer` apaga esse histórico.
  - **Junto:** a fila de mensagens durável. Hoje um reinício perde as mensagens que ainda não começaram, e cada deploy reinicia.
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
- **Slack, streaming nativo:** se o modelo cai no fallback sem streaming depois de já ter mandado texto, a conclusão pode não começar pelo texto já enviado. O `finish_progress` manda a resposta inteira, e a mensagem pode mostrar as duas versões. O caminho normal não é afetado. Corrigir pede uma decisão de desenho: reabrir a mensagem ou substituí-la. Origem: revisão da #40.
- **`StartHooks` por canal.** Os hooks de teste ainda têm campos de Telegram, Discord, Slack e Matrix, e `config.channel_support` marca Telegram e Discord como suportados pelo nome. Origem: #40.

### 3.3 Interação e computador

- **Interface de aprovação.** Botões de aprovar ou recusar antes de uma ação, com o ciclo de vida no Port. Origem: `UX.md` 4.
- **Computador, fase 2.** Encaixa com a interface de aprovação.
  - um computador por pessoa, apagado no `/esquecer`;
  - uma tela que a pessoa pode assumir (noVNC) para login e captcha;
  - confirmação garantida pelo código antes de qualquer efeito fora da máquina;
  - tarefas longas assíncronas.
- **Yield manual de sessão.** O checkpoint por orçamento e por tempo existe no executor. Uma ferramenta para a agente ceder a vez por conta própria nunca foi exposta. Origem: `IMPLEMENTATION_TODO.md` 2.5.

### 3.4 Observabilidade e desempenho

- **Observabilidade total.** Decidido em 22/11: Prometheus (histórico) e Grafana (painéis), acessíveis só pela máquina.
  - **Etapa 1, feita:** exposição no formato do Prometheus (um `TYPE` por família, buckets cumulativos com `+Inf`, escape, newline final; antes o `TYPE` repetido fazia o Prometheus recusar o scrape inteiro, e os histogramas não tinham buckets); durações em segundos; `agents_active` como gauge; o score de complexidade saiu dos labels. O tracer e o circuit breaker nunca eram encontrados no global (a checagem de vida recebia o Subject, não o pid): nenhum span era aberto e o breaker nunca era consultado. Corrigido; o breaker conta só indisponibilidade do provedor (rede, 5xx, 429). O `/metrics` "vazio no piloto" era efeito de restart: depois de uma conversa, ele está preenchido.
  - **Etapa 2, feita:** mensagens por canal, duração e desfecho de cada turno, respostas que não chegaram (antes descartadas em silêncio), recusas de fila, decisões do gate, tokens e custo, agenda, erros de poll; o caminho de streaming passa pelo mesmo span, breaker e métricas. Um log não derruba mais um turno cujo group leader morreu (`infra/safe_io`).
  - **Etapa 3:** Prometheus e Grafana no compose, com painéis.
  - **Sem uso:** `core/telemetry`, `core/dashboard` e `core/alerts/actor` não são importados por ninguém fora dos próprios módulos.
- **Readiness dos outros canais.** O `/health/ready` responde 503 quando um canal não está pronto e acompanha o Telegram a cada poll. Os demais canais só informam que subiram: um gateway do Discord que cai depois continua aparecendo como pronto. Entra junto com a paridade do Discord.
- **Benchmarks** (REQ-9). O código está em `test/bench/`, mas as metas de `BENCHMARKS.md` nunca foram medidas.
- **Teste de carga** (REQ-8). O código está em `tests/load/` e `run_load_tests.sh`. A meta (100 usuários, p99 < 2 s, erro < 1%) nunca foi verificada.
- **Verificação final da v1.** Faltam os critérios de `production-ready-v1`: spans visíveis, circuit breaker medido e nenhum `mock` em código de produção.

### 3.5 Qualidade

- **Cobertura, por risco.** Decidido em 22/11: cobrir primeiro o que tem mais risco, e subir o gate junto. Gate em 79%.
  - **Feito:** ciclo completo do circuit breaker; cliente real do Telegram contra uma Bot API local (`test/telegram_fake.gleam`): polling, offset, erros, backoff, streaming e "digitando", saída de grupos não autorizados com alerta e nova checagem, botões, erros de envio e o `inject` da agenda (`test/adapters/telegram_live_test.gleam`, `test/e2e/telegram_live_e2e_test.gleam`).
  - **Defeitos achados e corrigidos:** o breaker que só bloqueava uma vez; o stream abortado por "message is not modified"; o `retry_after` lido do lugar errado; um botão com mais de 64 bytes de `callback_data` derrubava a mensagem inteira (o `/model` com um modelo de nome longo ficava sem resposta).
  - **Próximo:** o Telegram restante são ramos de erro secundários. O Discord entra com a paridade.
  - `COVER_FUNCTIONS="modulo1 modulo2" make coverage` lista as funções descobertas de cada módulo.
  - Origem: retomada.
- **Testes com Chromium real no CI.** Hoje só rodam com `SUPERNOVA_BROWSER_TESTS=1`. O computador já roda os testes dele no CI. Origem: auditoria 3.4.
- **Failover entre provedores existe, mas não está ligado.** `llm/failover.gleam` (com cooldown por provedor) está pronto, e o ator de cooldown sobe no boot, mas nenhum caminho chama `failover.chat`: a agente usa um provedor só. Fica no código para quando houver um segundo provedor. Origem: medição de cobertura de 22/11.

### 3.6 Documentação

Feito em 22/11 (PR #37):

- `LICENSE` (MIT, confirmado pelo mantenedor) e `licences` no `gleam.toml`.

- `README.md`, `GETTING_STARTED.md`, `docs/STATUS.md`, `docs/operations/OBSERVABILITY.md`, `docs/operations/INTERACTION.md` e `docs/operations/DOCKER.md` foram reescritos com o que é verdade hoje, conferido no código e no piloto.
- A arquitetura ganhou grupo fechado, self, agenda, computador e harness.
- A raiz foi organizada:
  - os PRDs foram para `docs/prd/`, cada um com um bloco de situação;
  - os relatórios foram para `docs/relatorios/`, as notas de versão para `docs/releases/` e os planos antigos para `docs/arquivo/`.
- Saíram:
  - `docs/rag/`, o `scripts/fetch_docs.sh` e o `scripts/create_prs.sh`;
  - o `BENCHMARKS.md`, que estava vazio;
  - a cópia duplicada do CLI na raiz.
- As referências de canais ficaram em `docs/research/`, como retrato de março.

Ainda aberto:

- **O PRD N não tem relatório.**
- **`audit/` continua como está.** A auditoria de março está reconciliada em `audit/STATUS_2026-11.md`.

### 3.7 Riscos aceitos (revisitar)

Riscos aceitos nos relatórios, mantidos aqui para não se perderem.

**Fila e reinício**

- ~~A fila não é durável: um kill forçado perde as mensagens que ainda não começaram.~~ Saiu dos riscos aceitos em 22/11: cada deploy reinicia o container, então a fila durável será tratada junto com a preservação do histórico (3.1).
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
