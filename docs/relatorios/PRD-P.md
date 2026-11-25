# PRD-P: relatório final

[PRD](../prd/PRD-P-paralelismo.md) · [linha de base](PRD-P-base.md) · 23/11

## Resumo

A mensagem deixou de passar por um processo único em cada etapa. O roteador de
cada canal, a fila durável e o `file_server` eram processos únicos, e todas
as mensagens de todos os chats esperavam por eles. Hoje:

- **A fase anterior ao LLM** roda na fila de cada chat (`routing.parallel`,
  ligado por padrão).
- **O estado da agente** (`self_state`, relação, nascimento, `/esquecer`) tem
  um processo dono por agente.
- **A fila durável** grava em lote.
- **Os arquivos** são lidos e gravados em modo `raw`.

Sem buscas, a vazão subiu **1,73×**, e a mediana de latência caiu **4×**.
Nenhum turno respondido faltou em nenhuma rodada, com ou sem caos.

## Medição final

**Como foi medido.**
- **Carga:** 200 agentes, 10.000 mensagens semeadas por agente, 10 grupos,
  150 workers, 30 s.
- **Versões:** linha de base é o código da P-00b (`a8d7c65`), que passa pelo
  caminho de produção; nova é este branch.
- **Rodadas:** intercaladas sobre cópias congeladas.
- **Máquina:** compartilhada, 6 núcleos, carga entre 5 e 14 durante as
  rodadas.

### Sem buscas (`--search-every 1000000`), 3 pares

| Par | Base turnos/s | Nova turnos/s | Base p50 | Nova p50 | Base p95 | Nova p95 |
|---|---|---|---|---|---|---|
| 1 | 89,1 | 167,7 | 1481 ms | 357 ms | 3690 ms | 3821 ms |
| 2 | 96,8 | 172,0 | 1285 ms | 349 ms | 3923 ms | 3848 ms |
| 3 | 116,2 | 167,9 | 1171 ms | 353 ms | 2209 ms | 3718 ms |
| **Mediana** | **96,8** | **167,9 (1,73×)** | **1285 ms** | **353 ms** | **3690 ms** | **3821 ms** |

**Maior fila de um processo:**
- **Base:** 266–270, sempre a fila durável.
- **Nova:** 149, o coletor do cliente de teste (`sim_adapter.collect_stream`),
  que é a fila de um grupo esperando a sua vez. Nenhum processo da plataforma
  aparece no topo.

**Memória máxima:**
- **Base:** 403–428 MB.
- **Nova:** 456–462 MB, 1,1× a base.

### Com buscas (`--search-every 5`), 2 pares

| Par | Base turnos/s | Nova turnos/s | Base p50 | Nova p50 | Base p95 | Nova p95 |
|---|---|---|---|---|---|---|
| 1 | 59,8 | 58,1 | 1529 ms | 959 ms | 9067 ms | 9937 ms |
| 2 | 60,2 | 72,1 | 1518 ms | 744 ms | 8235 ms | 9034 ms |

A vazão fica onde estava. Com buscas, o teto é a própria `buscar_conversa`,
que varre o arquivo da conversa a cada chamada. O índice de busca estava fora
do escopo desta PRD.

### Caos (120 s, busca a cada 5, sessões mortas e restart no meio)

| Rodada | Respondidos | Faltando no disco | Desligamento | Boot de novo |
|---|---|---|---|---|
| nova 1 | 5249 | **0** | 3373 ms | 1369 ms |
| nova 2 | 4351 | **0** | 4486 ms | 4606 ms |
| nova 3 | 4390 | **0** | 5616 ms | 6933 ms |

**Três rodadas seguidas sem turno faltando.** Nessas rodadas, só 35–55% das
mensagens foram respondidas, e o desligamento levou de 3 a 6 s. Na rodada de
caos da P-05 tinham sido 89% e 0,7 s.

Para separar regressão de carga da máquina, o código da P-05 rodou
intercalado com o final:

| Rodada | Versão | Turnos/s | Run queue máx. | Desligamento | Faltando |
|---|---|---|---|---|---|
| 1 | P-05 | 35,0 | 1744 | 4850 ms | 0 |
| 1 | final | 36,6 | 1347 | 4797 ms | 0 |
| 2 | P-05 | 38,7 | 1523 | 4207 ms | 0 |
| 2 | final | 43,1 | 1842 | 3998 ms | 0 |

As duas versões se comportam igual. A queda veio da carga da máquina (10 a
14, com outro BEAM ocupando quase dois núcleos), não do código.

## Critérios da PRD (seção 9)

| Critério | Meta | Resultado |
|---|---|---|
| Vazão | ≥ 2× | **1,73×** sem buscas; empate com buscas. Não atingido. Veja abaixo. |
| Latência | p95 ≤ metade, sem buscas | **Não atingido no p95** (~3,8 s nos dois). O p50 caiu 4×. Veja abaixo. |
| Integridade | 0 faltando, com e sem caos, 3 rodadas seguidas | **Atingido.** 0 em todas as 16 rodadas. |
| Memória | pico ≤ 1,5× | **Atingido.** 1,1×. |
| Comportamento | suíte e harness verdes; I1–I7 | **Atingido.** Suíte inteira com o caminho paralelo por padrão; I1–I7 nos dois modos. |
| Roteador | fora do topo das filas | **Atingido.** Nenhum processo da plataforma no topo. |

**Por que a vazão parou em 1,73×.** Os processos únicos saíram do caminho,
então o que limita agora é a CPU. A máquina tem 6 núcleos e é compartilhada.
Nas rodadas de maior vazão, a carga do sistema chegou a 8 com o próprio teste
ocupando os núcleos, e a run queue da VM subiu junto. Numa máquina com mais
núcleos livres, a nova versão escala; a base não, porque esbarra num processo
único.

**Por que o p95 não caiu.** A cauda vem dos grupos. Um quinto das mensagens
vai para 10 grupos, e cada grupo responde uma mensagem de cada vez, em ordem.
Isso é a invariante I1, por desenho. Com 150 workers, a fila de um grupo
chega a 149 mensagens. A mensagem de um grupo espera as anteriores do mesmo
grupo, e essa espera é o p95. Os chats privados, que eram os que esperavam
pelo roteador, caíram para os ~350 ms do p50.

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| P-00 | `f9501e8` | linha de base (descartada: o sim pulava a fila durável e a fila do chat) |
| P-00b | `2f06296`, `a8d7c65` | o sim passa pelo `channel_kit`, como os canais reais; nova linha de base |
| P-01 | `7e81018` | testes das invariantes I1–I7, com a Supernova inteira e mensagens simultâneas |
| P-02 | `d53f7f0` | `self/desk`: um processo por agente, único que grava `self_state` e relação; gravação atômica |
| P-03 | `f645e97` | `/esquecer` espera os turnos em andamento da pessoa (D2); nascimento exclusivo por agente (D3) |
| P-04 | `5799c51` | o estado do roteador vai para ETS |
| P-05 | `c68d13f` | a fase anterior ao LLM na fila do chat, atrás de `routing.parallel` |
| P-06 | `cdea93f` | fila durável com gravações agrupadas; arquivos em modo `raw` |
| P-07 | este | `routing.parallel: true` por padrão; documentação; este relatório |

Fora da PRD: `aaa6b0d` corrige um teste do harness que falhava às vezes.

## Corridas resolvidas

- **Gravações perdidas no estado da agente.** Com 200 mudanças simultâneas na
  relação, o caminho antigo guardava 1 e o processo da agente guarda as 200.
- **`/esquecer` com turno em andamento em outro chat.** Antes, o turno perdia
  a sessão e a pessoa ficava sem resposta. Agora o `/esquecer` espera o turno
  (até 60 s), a resposta chega, e o que foi dito é apagado junto.

## O que fica

- **Remover `routing.parallel: false` e o caminho pelo ator do canal** depois
  de uma semana no piloto sem regressão (P-07). Entra no PENDENCIAS.
- **Índice para a `buscar_conversa`.** Com buscas, ela é o teto.
- **Medir a vazão de novo numa máquina mais livre**, para saber quanto da
  diferença até 2× é CPU da máquina compartilhada.
