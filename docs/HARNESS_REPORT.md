# Harness: relatório de execução

Baseline em `28cf907` (Gleam 1.19.2, Erlang 28.5.0.8): **2351 testes**,
cobertura **75.67%** (`10208/13491` linhas, `STATUS.md`).

## História → testes

| História | Testes |
|---|---|
| H-00 | `test/self/drift_apply_test.gleam` (validação 20/200 palavras, recuperação após cada passo, sem lock ffi) |
| H-01 | coberto indiretamente pelo boot real dos testes de harness; `src/supernova/harness/clock.gleam` |
| H-02 | `test/e2e/sim_e2e_test.gleam` (turn_end), `test/harness/run_test.gleam` (prompts/recusa) |
| H-03 | `test/harness/scenario_test.gleam` |
| H-04 | `test/harness/cli_model_test.gleam` (fixtures reais de `omp`/`claude`, executáveis falsos) |
| H-05 | `test/harness/engine_test.gleam` |
| H-06 | `test/harness/checks_test.gleam` |
| H-07 | `test/harness/judge_test.gleam` |
| H-08 | `test/harness/judge_test.gleam` (calibração com o mock) |
| H-09 | `test/harness/cost_test.gleam`, `test/harness/run_test.gleam` (teto e parcial) |
| H-10 | `test/harness/run_test.gleam` (ponta a ponta, segredo, custo) |
| H-11 | mock em `src/supernova/llm/client.gleam`, exercitado por H-05..H-10 |
| H-12 | este documento e `docs/HARNESS.md` |

## Decisões tomadas durante a execução

- O boot escolhe a porta efêmera do health server e desliga o varredor horário
  quando `environment` é `harness`; `main` continua no caminho de produção.
- O provedor `mock` passou a existir no enum de configuração, para o CI rodar o
  harness inteiro sem rede.
- O adendo provisório do mock tem 60 palavras, e marcadores
  `[mock-drift-20]`/`[mock-drift-200]` pedem os casos inválidos.
- `turn_end` entra no transcript da execução, mas os testes antigos de contagem
  do canal `sim` o ignoram explicitamente.
- O transcript de calibração é mais livre que o da execução: campos de chat,
  sequência e passo são opcionais.
- O juiz recebe o transcript numerado como argumento posicional do `claude`
  (o CLI aceita o prompt assim); personas continuam por arquivo `@`.
- O custo do juiz é lido de `total_cost_usd`; no modo mock é zero.
- `data_dir` de cada execução é apagado ao fim, salvo `--keep-data`; o
  transcript fica fora dele.

## Limitações conhecidas

- O conteúdo real de `priv/harness/` (personas, cenários, rubricas, prompts e
  calibração) é do mantenedor. Os arquivos deste commit são provisórios e estão
  marcados como tal.
- Nenhuma execução real com `omp`/`claude` foi feita: só fixtures e executáveis
  falsos.
- A calibração e o relatório foram exercitados com o mock; os números de custo
  reais só aparecem quando o mantenedor rodar com modelos de verdade.
