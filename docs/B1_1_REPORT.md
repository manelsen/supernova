# Relatório B1.1 — rodada 2

Branch `fix/b1-1-endurecimento`, PR #13. Base rebaseada em `origin/master`
depois do merge do PR #12.

## Defeito → correção → teste

| # | Defeito | Correção | Teste |
|---|---|---|---|
| R-01 | Reserva usava o preço do primeiro provider de `dict.values` | `admit_llm` recebe provider/modelo e usa `model_price` do modelo roteado | `admission_uses_routed_model_price_test` |
| R-02 | Uma reserva cobria até três tentativas; falha de rede liberava custo | Cada tentativa tem `:aN` e admissão própria; `NetworkError` vira uso estimado `:unconfirmed`; 4xx/5xx liberam | `network_failure_once_is_unconfirmed_and_retried_test`, `retry_429_releases_every_reservation_test`, `retry_second_attempt_can_be_denied_by_cap_test` |
| R-03 | Retries usavam o handle de ledger capturado | `get_ledger` no global é resolvido em cada tentativa e no release final | `usage_retry_uses_live_ledger_test` |
| R-04 | Admissão contava só reservas do dia informado | Ledger calcula o dia e conta todas as reservas abertas | `open_reservations_count_across_day_boundary_test` |
| R-05 | Falha de `list_admins` caía para os admins do YAML | `try_list_admins`; `Ok([])` avisa, `Error` audita `alert_dropped` e não envia | `alerts_only_reach_effective_admins_test`, `alert_is_dropped_when_access_is_unavailable_test` |
| R-06 | ID de reserva repetia; executor vinha antes da cobrança; claimed_tools crescia | `unique_integer` no ID; claim só após `try_record_consumption`; `ToolCompleted` retira o claim; estorno só na mesma janela horária | `thousand_tool_reservations_have_unique_ids_test`, `claim_is_refused_when_budget_is_unavailable_test`, `completed_tool_cannot_be_refunded_test`, `late_claim_retry_charges_once_test` |
| R-07 | Drain começava com polling ativo e reabria após timeout | `stop_ingress` em cada adaptador antes do drain; Telegram espera o lote atual; prefixo continua fechado após timeout; `undrain` explícito; validação de argumentos | `drain_validates_arguments_test`, `drain_timeout_keeps_prefix_closed_test`, `stop_channels_stops_ingress_before_adapters_test` |
| R-08 | `turn_hard_timeout_ms` do hook não era usado | Prazo threaded até `await_late_terminal`; constante só é default | `hard_turn_timeout_releases_the_next_turn_test` |
| R-09 | Achados de acesso e callback negado | `adjust_list` limpa `added` ao revogar e `removed` ao reconceder; callback negado audita e conta abuso | `command_only_admin_grant_and_revoke_survive_restart_test`, `yaml_member_revoke_then_regrant_clears_removed_test`, `denied_interaction_is_audited_test` |

## Riscos aceitos / trabalho futuro

- Matrix: limite de tamanho codificado em edits; fora do escopo B1.
- Discord: espera subsegundo de `retry_after` é truncada para segundos.
- TTL de reserva usa relógio de parede, não monotônico.
- Reduzir o teto não invalida reservas já abertas; elas valem até liquidar/expirar.
- IDs de chamada legados não são restart-safe.
- Admissão que chega após o timeout do chamador expira sozinha em 10 min.
- Docker/docs/CI não foram o foco; as correções triviais de `workflow_dispatch` e build-only ficaram no PR.
- Retry 429 do placeholder e corte pelo orçamento restante continuam como estão.
- Estorno de claim usa buckets de hora de parede; a janela do budget começa no
  primeiro uso, então um cancelamento na virada pode não estornar.
- Não há mock HTTP do `getUpdates`; o teste de desligamento cobre a ordem
  ingress→drain e o prefixo fechado, e o polling só confirma o offset depois de
  entregar o lote ao callback.
- Falhas `APIError` 5xx liberam a reserva e não geram uso estimado; a maioria
  dos provedores não cobra 5xx. Falhas de rede são tratadas como possivelmente
  cobradas e viram `:unconfirmed`.

## Respostas a comentários desatualizados

- `access/pure.gleam` já era suspeito de limpar apenas um dos lados do delta;
  os testes de restart desta rodada expuseram e corrigiram os dois casos.
- O recheck de autorização antes do retry de saída já existia; sem alteração.
- Os demais comentários de segurança/migração v1 seguem o desenho do PRD
  anterior e estão documentados como risco aceito.

## Gates

- Baseline antes da rodada: 2201 testes, 75,81% de cobertura; Gleam 1.19.2.
- Final: 2220 testes, 0 falhas; cobertura de linha 75,99% (10659/14027).

## Commits da rodada 2

- `6ccdfd8` R-01
- `f33f5cf` R-02
- `e42ff6d` R-03
- `9a1c500` R-04
- `2738a1b` R-05
- `2211f29` R-06
- `af9a57c` R-07
- `172b48b` R-08
- `24a58e1` R-09
- `docs: record B1.1 review round 2` R-10

## CodeRabbit

- Rodada de 14:08 (comentários no PRD): a reserva da tentativa não confirmada
  agora é liberada no ledger vivo antes de registrar `<id>:unconfirmed`
  (`255e2c8`); a cobrança de ferramenta já remove a reserva no primeiro claim,
  e `late_claim_retry_charges_once_test` (`aab29e8`) prova que o retry tardio
  não cobra de novo. O caso de valores do teste de admissão era sobre o texto
  do PRD; o teste implementado usa valores que passam.
- Review solicitado no head final; threads não foram respondidas nem resolvidas.
