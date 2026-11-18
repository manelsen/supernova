# PRD B1 — Relatório de Execução

## Linha de base e estado final

| Métrica | Início | Final |
|---|---|---|
| `gleam test` | 2007 passaram, 0 falhas | 2158 passaram, 0 falhas |
| Cobertura de linhas | 74,56% (gate 73) | 75,67% (10208/13491, gate 75) |
| `gleam build --warnings-as-errors` | verde | verde |
| `gleam format --check src test` | verde | verde |

Ambiente: Gleam 1.19.2 / Erlang 28.5.0.8, Linux x64.

## Caminho de uma mensagem

```text
canal (Telegram/Discord)
  → principal (channel:user_id)
  → acesso (allowlist/admin/member, chat autorizado, rate limit)
  → comandos (/eu, /uso, /acesso, /teto, /auditoria) [sem LLM]
  → orçamento por principal + teto global diário
  → LLM
  → SyscallGateway: capability → workspace → orçamento de ferramenta
                    → execução → ledger → audit log
  → ledger (tokens, ferramenta, custo) + audit log + alertas
  → resposta do canal (chunking 4096/2000)
```

Componentes:

- `core/principal.gleam`: identidade separada da sessão.
- `core/access/{types,pure,actor}.gleam`: decisão pura, listas persistentes em
  `<data_dir>/access.json`, avisos de negação de 24 h.
- `core/closed_group/{types,pure,runtime,global}.gleam`: gate único antes do
  LLM, comandos, orçamento/teto, contexto do executor, alertas e auditoria.
- `core/budget_policy/`: janela por hora (`tokens_per_hour`,
  `tool_calls_per_hour`) e fail-closed.
- `core/resource_ledger/`: trilha por principal em
  `<data_dir>/ledger/YYYY-MM-DD.jsonl`, rotação de 30 dias.
- `core/syscall/actor.gleam`: `invoke_tool/5` com pipeline do kernel.
- `core/tool_dispatch.gleam`: única module que importa `supernova/tools/*`.
- `core/alerts/{group_pure,group_actor}.gleam`: deduplicação de alertas.
- `core/instance_budget/`: teto diário ajustável por `/teto liberar`.
- `config_check.gleam` + `check_config_main.gleam`: validação no boot e CLI.
- Audit log: `<data_dir>/audit_log/<agent>/.supernova/audit.log`, texto com
  `timestamp agent operation target result details`; rotação ao passar de
  10 MB, mantendo cinco backups (`audit.log.1` … `.5`).

## Padrões de segurança

| Item | Padrão |
|---|---|
| Acesso | `allowlist`, listas vazias; ninguém usa até configurar |
| Chats/grupos | lista vazia; só conversas privadas de principals autorizados |
| Capabilities `member` | `web`, `web_fetch`, `file_system`, `canvas`, `github`; nega `safe_shell`, `process`, `browser`, `gateway` |
| Capabilities `admin` | `*` |
| Orçamento `member` | 50.000 tokens/h, 60 ferramentas/h |
| Orçamento `admin` | ilimitado (`-1`) |
| Rate limit `member` | 10 mensagens/minuto |
| Rate limit `admin` | ilimitado (`-1`) |
| Teto global | US$ 5,00/dia, `America/Sao_Paulo` |
| Falha de access/budget/ledger | nega (fail-closed), mensagem interna genérica |
| Audit log | sem conteúdo de mensagem do usuário |

## Decisões sem especificação explícita

- O runtime de grupo fechado é publicado em `persistent_term` e reconstruído a
  partir dos handles supervisionados; um ator reiniciado é reutilizado sem
  reiniciar o processo inteiro.
- O gate retorna `Ignored` (sem resposta) para grupos não autorizados, exceto
  `/eu`; administradores podem autorizar o chat corrente com `/acesso chat
  adicionar`.
- O limite de mensagens usa janela deslizante de 60 s; comandos e `/eu` não
  contam.
- Em servidores Discord, a autorização usa o `guild_id` (`discord:guild:<id>`);
  o id do canal viaja anotado como `<canal>@guild:<guild>` e é removido antes
  de chamar a API. Alertas abrem DM via `/users/@me/channels`.
- Se o ator de acesso estiver indisponível, os alertas usam a lista de admins
  da configuração como fallback para não silenciar falhas.
- Prova do teste de isolamento: um `import supernova/core/blackboard` temporário
  em `src/supernova.gleam` fez `test/architecture/isolation_test` falhar;
  removido o import, o teste voltou a passar.
- O teto diário considera o dia no fuso configurado; o arquivo do ledger usa
  dias UTC, e a soma diária é filtrada pelo timestamp no fuso.
- O custo de uma chamada é estimado com `pricing` e registrado no ledger; a
  estimativa de tokens usa `usage` quando disponível no provider e, caso
  contrário, caracteres/4.
- Alertas são deduplicados por tipo+sujeito por uma hora; o envio usa o
  principal do admin como destino DM.
- A saída para canais suportados usa os limites existentes de chunking
  (Telegram 4096, Discord 2000).

## Cobertura

`make coverage` mediu **75,67%** (10208/13491 linhas). O alvo de 78% não foi
alcançado sem testes artificiais: os maiores buracos restantes são módulos de
canais/rede (`channel/registry` 249 linhas, `discord_commands` 169,
`telegram` 159, `discord_webhooks` 105, `whatsapp_adapter` 92) e o bootstrap
(`supernova` 134), que exigem harness HTTP/Chromium ou sobem o processo inteiro.
O threshold foi fixado no maior valor honesto arredondado para baixo, **75**,
acima da linha de base de 74,56%.

## Branch, commits e CI

- Branch: `feat/grupo-fechado`
- Commits: série temática (`ci`, `git_inspect`, `config`, `ledger`, `gateway`,
  `access`, `isolation`, `docs` e as correções de fechamento).
- PR: https://github.com/manelsen/supernova/pull/12
- CI: quality gates rodados localmente; o run do PR está em
  `gh pr checks 12`.

## Observações

- `blackboard` e `memory_federation` continuam desligados; há testes de
  arquitetura em `test/architecture/isolation_test.gleam`.
- Os testes de ponta a ponta de Telegram e Discord usam o registry real com
  HTTP mock/hooks determinísticos, sem rede.

## Correções pós-revisão (18/11)

A revisão do PR encontrou problemas de concorrência e de autorização. Todos
têm teste que falhava antes da correção.

| Problema | Efeito | Correção |
|---|---|---|
| Turnos com barreira rodavam dentro do ator do router | Cada turno de LLM bloqueava o router de todos; acima de 30 s, o processo chamador caía | O turno sempre roda num processo próprio; o router responde na hora com o indicador de digitação |
| O laço de polling consumia o stream do turno | Um turno lento travava todos os outros chats do canal | Fila por chat (`supernova_chat_lanes_ffi`): chats diferentes em paralelo, o mesmo chat em ordem |
| O gateway executava a ferramenta dentro do ator | Fila global de ferramentas; ferramenta acima de 2 s era dada como recusada mas continuava executando | O gateway só autoriza (e já desconta o orçamento); a ferramenta roda no processo do turno; o resultado vai ao audit log por mensagem |
| Papel `"membro"` no contexto, manifestos com chave `"member"` | Membros não conseguiam usar nenhuma ferramenta | `role_key` estável (`admin`/`member`) para contexto e manifestos; `role_name` só para exibição |
| Cliques em botões não passavam pela barreira | Não membro podia trocar provider/modelo de uma sessão compartilhada | Interações passam pela mesma barreira das mensagens |
| Recusa do kernel no caminho assíncrono virava `StreamFailure` | O usuário ficava vendo "Thinking..." sem explicação | A recusa chega como mensagem final |
| Mensagem final do stream não era dividida | Edição acima de 4096 (Telegram) ou 2000 (Discord) caracteres era rejeitada | A primeira parte edita o placeholder; as demais vão como mensagens novas |
| Teto diário copiava o histórico inteiro do ledger a cada chamada ao LLM | Ficava mais lento com o tempo e podia falhar fechado sem motivo | A soma do dia é feita dentro do ator do ledger |
| `handle_message` público rodava sem kernel | Caminho sem orçamento nem gateway, sem chamadores | Removido; o contexto vazio do executor passou a ser `member` |

Estado após as correções: `gleam test` 2167 passaram, 0 falhas; cobertura
75,75% (gate 75); `gleam build --warnings-as-errors` e `gleam format --check`
verdes.

## Correções da revisão CodeRabbit (Fase A)

A revisão do CodeRabbit em `1a2259c` formalizou 10 histórias de endurecimento.
Todas entraram no PR #12 com teste que reproduzia a falha.

| História | Problema | Correção | Teste |
|---|---|---|---|
| A-01 | `access.json` gravava listas efetivas e o YAML deixava de revogar | Deltas `added`/`removed` sobre a base YAML, com migração do formato antigo | `yaml_revocation_survives_denials_test`, `legacy_full_list_file_is_migrated_test` |
| A-02 | Falha da política de workspace deixava o boot seguir sem checagem de caminhos | Boot falha; gateway nega caminhos quando há manifestos e não há política | `supervisor_fails_when_workspace_policy_cannot_start_test`, `capabilities_without_workspace_policy_deny_file_operations_test` |
| A-03 | Admin executava relatórios em grupo não autorizado | Só `/eu` e comandos de gestão de chat dispensam a checagem do chat | `admin_report_requires_authorized_chat_test` |
| A-04 | `git branch -D`, `--output`, `--no-index` etc. passavam | Allow-list de opções e limite de posicionais por subcomando; caminhos passam pelo `workspace_guard` | `safe_shell_rejects_git_write_options_test`, `safe_shell_allows_bounded_git_operands_test` |
| A-05 | Timeout do acesso virava lista vazia e o bot saía do grupo | `try_list_chats` e `chat_authorized_result`; falha não sai, audita e recheca em 30 s | `access_lookup_failure_does_not_leave_group_test` |
| A-06 | Compose não encaminhava token/allowlist nem preservava `data_dir` | Env do Telegram/access, `SUPERNOVA_DATA_DIR=/data` e volume nomeado | Inspeção do compose + smoke Docker |
| A-07 | Fila aceitava jobs sem limite | 50 pendentes por chat, 2000 lanes, `submit` devolve `Bool` | `lanes_reject_pending_turns_above_limit_test`, `lanes_reject_new_chats_above_lane_limit_test` |
| A-08 | Fila liberava antes de o turno terminar | Espera até 300 s pelo evento terminal e entrega o conteúdo atrasado como mensagem nova; exceções viram `StreamFailure` | `late_terminal_keeps_lane_until_content_is_delivered_test`, `executor_crash_emits_stream_failure_test` |
| A-09 | Testes de assincronia, recusa e concorrência liam uma vez ou usavam prazos ociosos | `await_content` com prazo total, auditoria com polling de 2 s, mock delay, recusa exata e liberação por subject | Testes citados acima + `slow_tool_neither_refused_nor_blocking_test` |
| A-10 | Fechamento | Esta seção, push e CI | `gh pr checks 12` |

Estado após a Fase A: `gleam test` 2184 passaram, 0 falhas; `gleam build
--warnings-as-errors` e `gleam format --check` verdes. A cobertura foi medida
com `make coverage` no fechamento.

## Correções da Fase B (B1.1)

A Fase B fecha os riscos de custo, entrega e concorrência levantados pela
revisão. Cada linha tem teste automatizado no PR "B1.1".

| História | Problema | Correção | Teste |
|---|---|---|---|
| B-01 | Estimativa de tokens ignorava definições de ferramentas e chamadas de ferramenta | `tool_definition_tokens`, `message_token_estimate` e `response_token_estimate` entram em `prompt_token_estimate` | `tool_definitions_and_calls_are_counted_in_estimates_test` |
| B-02 | Cada consulta ao teto diário relia o ledger inteiro | Totais por dia mantidos no ator, reconstruídos na rotação e recarregados no boot | `persistence_survives_restart_test` |
| B-03 | Duas chamadas concorrentes podiam passar pelo teto antes de qualquer cobrança | Reserva do custo estimado na admissão, liberada ou substituída pela cobrança real; dia do ledger explícito | `concurrent_admissions_respect_the_cap_test` |
| B-04 | Falha de escrita no ledger perdia custo | `call_id` idempotente, três retentativas e alerta `ledger_write_lost` | `usage_retry_is_idempotent_test` |
| B-05 | Entrega dividida tratava "mensagem não modificada" como falha e não repetia 429; updates acima do limite quebravam o consumidor | `not_modified` é sucesso, partes com 429 são repetidas até 10 s, fallback final, updates grandes ignorados | `split_delivery_treats_not_modified_as_success_test`, `split_delivery_retries_rate_limited_parts_test` |
| B-06 | Saída do grupo era auditada antes de o Telegram confirmar | Auditoria só após confirmação; retentativas rechecam a autorização antes de cada tentativa | `failed_group_leave_is_retried_and_audited_test` |
| B-07 | Interação de não membro podia editar um seletor compartilhado | Interações passam por `gate_interaction`; negação não carrega `edit_message_id` | `interaction_from_non_member_is_gated_test` |
| B-08 | Shutdown parava dependências antes de drenar as lanes | Fila prefixada por registro, `drain` com prazo e `stop_channels_with_timeout` | `drain_reports_pending_turns_with_short_timeout_test` |
| B-09 | Autorização descontava orçamento mesmo sem execução | Cobrança transferida para `ClaimTool`; reserva expira em 5 s; `CancelToolClaim` estorna claim tardio | `unclaimed_tool_authorization_does_not_charge_test`, `cancelled_claim_refunds_budget_test` |
| B-10 | Fechamento | Riscos aceitos, notas e PR | `gh pr checks` |

### Riscos aceitos

- **Kill forçado de um worker de lane** perde jobs ainda não iniciados; não há
  fila durável. O `drain` de 25 s cobre o caso normal; job iniciado recebe até
  300 s para chegar a um evento terminal.
- **Reserva de saída** usa `reserve_output_tokens` (padrão 1000). O provedor
  não expõe hoje um limite de saída por chamada; uma resposta acima da reserva
  é contabilizada pelo custo real e pode ultrapassar o teto em uma chamada. O
  alerta de 80%/100% e o registro no ledger permanecem.
- **Reserva de 10 min** existe para chamadas órfãs. Uma chamada de LLM que
  dure mais que isso libera a reserva antes de terminar; o custo real continua
  sendo cobrado quando chega.
- **Migração de `access.json` legado** segue o PRD: listas antigas viram
  `added = listas − YAML` e `removed = []`. Uma revogação feita por comando
  antes da migração pode reaparecer; o admin deve revisar a lista após a
  primeira subida. A migração é única e regrava o arquivo no formato novo.
- **Fila durável de uso perdido** não foi implementada; após três tentativas o
  custo é auditado e alertado, mas não entra no total diário. O teto falha
  fechado no próximo `AdmitLLMCall` porque o gasto conhecido é menor que o real.

## Linha de base e estado final

| Fase | Testes | Cobertura de linha | `gleam build --warnings-as-errors` |
|---|---|---|---|
| Base pós-PR #11 (`1a2259c`) | 2167 | 75,75% | verde |
| Fase A (`b71e09d`, PR #12) | 2184 | 75,67% | verde |
| Fase B (PR "B1.1") | 2199 | 75,80% (10547/13915) | verde |

## Commits e CI

- Fase A: `b71e09d` `fix: harden closed-group access and channel execution`
  no PR #12; CI `test` run 44303926982 e `docker` run 44303926937, ambos
  verdes.
- Fase B (branch `fix/b1-1-endurecimento`):
  - `c0ae525` `fix(budget): count tool definitions and tool calls in usage estimates`
  - `09a9532` `perf(ledger): keep daily totals and reserve LLM spend`
  - `c1c63c1` `fix(channels): make stream delivery, leaves and shutdown resilient`
  - `f980fd9` `fix(router): gate interactions and retry lost ledger writes`
  - `54e1803` `fix(gateway): charge tool calls on claim and refund cancellations`
  - `618634b` `docs: accepted risks and v0.4.0 notes for B1.1`
  - CI do PR "B1.1" registrado na conversa do PR.

## Decisões sem especificação explícita

- A migração do `access.json` antigo segue o desenho do PRD (`added =
  listas − YAML`, `removed = []`). O risco de revogação por comando
  reaparecer está em "Riscos aceitos" e deve ser reconciliado pelo admin.
- O worker do turno mantém a lane ocupada até o evento terminal ou até
  `turn_hard_timeout_ms`; depois disso o PRD manda encerrar e logar. O job não
  é cancelado à força para não matar escrita de sessão em andamento.
- Reservas de custo expiram em 10 min, como o PRD pede; a cobrança real
  substitui a reserva pelo `call_id`.
- A fila de retentativa do ledger é em memória. Após três tentativas o custo é
  auditado e alertado, mas um restart pode perder o registro.
- `leave_group` no hook de teste devolve `Bool` para simular confirmação do
  Telegram sem rede.

## Revisões CodeRabbit

| Rodada | Onde | Achados | Resolução |
|---|---|---|---|
| 1 | PR #12, revisão `5956360197` | 8 | Recheck de autorização antes do retry de saída (`f980fd9`) e cancelamento de claim cobrado (`54e1803`) corrigidos. Migração legada, timeout duro, reserva de saída, TTL de 10 min e fila de retry seguem o desenho explícito do PRD e estão em "Riscos aceitos". Commit antes do push atendido. |
| 2 | PR #12, revisão `5956755462` | 12 | `bf3a25c`: YAML preservado quando a env do Compose está vazia; submissão de lane expirada não começa; log de recusa fora do receive; DEPLOY corrigido (revogação e volume). Aviso de fila cheia, timeout duro e revisão da migração v1 seguem o PRD e estão em Riscos aceitos. |
| 3 | PR "B1.1" | a preencher | a preencher |
