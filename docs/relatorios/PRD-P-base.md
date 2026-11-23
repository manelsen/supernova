# PRD-P: linha de base (P-00)

Medida em 23/11/2026 na master `efac5c4`, com as #60 a #62. Comando:

```sh
gleam run -m supernova/stress/run -- --agents 200 --history 10000 \
  --groups 10 --workers 150 --seconds 30 --search-every <N> --no-chaos
```

A carga é de 200 agentes, cada uma com 10 mil mensagens no privado e 2 mil no
grupo (2,4 milhões no total), e 150 workers. A máquina é compartilhada: a carga
média no início de cada rodada está na coluna "carga".

| Rodada | Carga | Turnos/s | p50 | p95 | p99 | Memória máx. | Faltando |
|---|---|---|---|---|---|---|---|
| sem buscas 1 | 8,9 | 121,5 | 1132 ms | 1759 ms | 2549 ms | 438 MB | 0 |
| sem buscas 2 | 5,6 | 129,9 | 1060 ms | 1655 ms | 2445 ms | 441 MB | 0 |
| busca a cada 5, 1 | 9,7 | 47,1 | 1413 ms | 8121 ms | 13774 ms | 699 MB | 0 |
| busca a cada 5, 2 | 6,9 | 45,9 | 1490 ms | 13048 ms | 14618 ms | 895 MB | 0 |
| caos, 120 s, busca a cada 5 | 8,7 | 94,9 | 1275 ms | 3402 ms | 8207 ms | 914 MB | 0 |

**Medianas da linha de base:**

| Carga | Turnos/s | p95 |
|---|---|---|
| sem buscas | **126** | **1,7 s** |
| com buscas | **46** | **~10 s** |

## Caos

- 20 sessões mortas no meio da carga.
- Desligamento sob carga: 181 ms. Boot de novo: 466 ms.
- 679 envios falharam na janela do restart, como esperado, e 11 turnos deram
  erro, por causa das sessões mortas.
- Nenhum turno respondido faltou no disco.

## Processo com a maior fila

Em todas as rodadas, o processo com a maior fila é o **roteador do canal**,
parado em chamadas síncronas do gate. Nas amostras com fila acima de 20:

| Chamada do gate | Sem buscas | Com caos |
|---|---|---|
| `resource_ledger.try_spend_today` (`precheck`) | 14x | 78x |
| `rate_limit.check` | 5x | 4x |
| `access.try_check` | 3x | — |
| `budget_policy.set_budget` | — | 10x |

Esse é o teto que a PRD-P ataca: tirar o roteador do caminho (P-05) e, se o
gate virar o próximo teto, levar as leituras dele para ETS (P-06).

## Fora da PRD-P

- **Memória com buscas.** O pico chega a 700–900 MB: cada busca carrega as 12
  mil mensagens da pessoa, e várias rodam ao mesmo tempo. Isso confirma o
  índice da busca como próxima PR à parte.
- **p95 com buscas (8–13 s).** Vem do custo da própria busca, que não é
  objeto desta PRD.
