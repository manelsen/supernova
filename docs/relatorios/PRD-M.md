# PRD-M: relatório final

[PRD](../prd/PRD-M-memoria.md) · [bancada](BUSCA-bancada.md) · PR #66, #67 e #68 · 24/11

## Resumo

A agente passou a lembrar do que foi dito. Três peças:

- **Porteiro:** um modelo pequeno lê só a mensagem que chegou e diz se ela
  pergunta sobre o passado. Se diz que sim, a pré-busca chama o `lembrar` antes
  do LLM e entrega o resultado como chamada de ferramenta.
- **`lembrar`:** procura em trechos de 10 mensagens, com lista curta (30 por
  vetor e 10 por palavras) e tom pela probabilidade.
- **Custo:** cada chamada é admitida no ledger antes e liquidada depois, como
  manda o `AGENTS.md`; sem ledger, a memória sai do caminho.

Tudo fica **desligado por padrão** (`conversation.recall.enabled: false`). Com
a configuração desligada, as mensagens ao LLM são idênticas às de antes.

O fornecedor mudou no caminho. A #67 entregou com o Gemini Decision 1; a #68
trocou o padrão para o **Perplexity Decider v1.3 27B**, com o Gemini
disponível por configuração (`conversation.recall.provider`). Os cortes de
probabilidade são por fornecedor, porque as escalas são diferentes, e o yaml
só sobrescreve um corte com medição nova. O índice guarda o modelo junto de
cada vetor, então trocar de fornecedor refaz o índice sem misturar vetores.

## Medição final

**Harness `buscar_antigo`** (DeepSeek V4.1 Flash, juiz Opus), 3 execuções de
cada lado, medido com o Gemini:

| Condição | Aprovadas |
|---|---|
| sem memória | **1 de 3** |
| com memória | **3 de 3** |

Nas reprovadas sem memória, a agente diz "Não sei. Nunca me contou o nome
dele" e só depois se corrige.

**Harness com o Decider** (cenário `buscar_antigo_memoria`): **2 de 2
aprovadas**, US$ 0,17.

**Bancada contra o código real:**

| Medida | Gemini (#67) | Decider (#68) |
|---|---|---|
| Fatos | 24/24 | 24/24 |
| Negação dura no nunca dito | 0 | 0 |
| Porteiro | 15/15 e 0/30 | 48/48 na bancada; 20/20 e 0/40 em 60 mensagens novas |
| Falhas do Decision | 0 | 0 |
| Turno inteiro (mediana) | 3,4 s | 5,5 s |
| `lembrar` | ~6,4 mil tokens, 0,65 s | ~5,7 mil tokens, 2,3 s |

**Linha de base descartada:** o DeepSeek em sim/não como porteiro quase empata
fora da amostra (14/15 contra 15/15, os dois com 0/30), mas perde as perguntas
implícitas ("qual é o telefone da clínica?"). Com múltipla escolha, o Decider
fez 20/20 nas sobre o passado e 0/40 nas novas. A formulação escolhida foi
testada cinco vezes em 131 mensagens já vistas, com 3,6 log-odds de margem
contra menos de 1 nas outras, e validada **uma vez** em 60 mensagens escritas
antes do ajuste.

**LongMemEval S** (corpus externo, MIT): a lista curta conteve a resposta em
59/59 perguntas com o Gemini e 59/60 com o Decider. Uma conversa foi recusada
pelo filtro de segurança do Google.

**Cobertura:** 80,17% na #67 (caiu na M-05 e voltou no `d87902c`); 80,28% na
#68.

## Critérios da PRD (seção 9)

| Critério | Meta | Resultado |
|---|---|---|
| Fatos achados (bancada) | ≥ 80% | **Atingido.** 24/24. |
| Negar com certeza (bancada) | ≤ 5% | **Atingido.** 0/24. |
| Porteiro em mensagens comuns | 0 disparos em 30 | **Atingido.** 0/30 com o Gemini; 0/40 nas novas com o Decider. |
| Atraso em mensagens comuns | p95 do porteiro ≤ 1 s | **Não medido como p95.** O porteiro tem tempo-limite de 2 s e roda em processo à parte; a mediana do turno inteiro está na tabela acima. |
| Custo por `lembrar` no tamanho do piloto | mediana ≤ US$ 0,002 | **Não medido.** O que existe é o preço por milhão de tokens (US$ 0,02 no Decider) e ~5,7 mil tokens por consulta. |
| Lista curta (LongMemEval, 59 respondíveis) | contém a resposta em ≥ 58 | **Atingido.** 59/59 e 59/60. A faixa "acho que não" (< 0,2) erra em 2/59. |
| Falha do Decision | nenhuma resposta de erro à pessoa | **Atingido.** Recusa por segurança, erro ou tempo esgotado viram texto que aponta para a `buscar_conversa`. |
| Harness | `buscar_antigo` passa, com e sem `recall` | **Parcial.** Passa 3/3 com a memória e 1/3 sem. Sem memória, o cenário existe para medir a diferença; ele reprova por desenho. |
| Piloto, primeira semana | taxa de correção medida e registrada | **Não feito.** Nada rodou no piloto; ligar é decisão do mantenedor, e antes é preciso conferir que a chave está no plano pago. |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| M-01 | `3f6dc83` | cliente do Decision e embeddings, transporte injetável e tempo-limite próprio; `conversation.recall`; o boot recusa memória ligada sem chave |
| M-02 | `ba0627c` | ferramenta `lembrar`: trechos de 10 mensagens, índice em `conversations/recall.idx`, lista curta, pergunta geral e tom por faixa |
| M-03, M-04 | `d5dcbff` | porteiro (só a mensagem, 2 s) e pré-busca em `executor_messages_for_turn`, o ponto por onde todo caminho de turno passa |
| M-05 | `87d362a`, `d87902c` | custo no ledger como uso de "gemini" e limite do dia; boot e ledger testáveis, cobertura de volta |
| M-06 | `9b01f4c` | cenário `buscar_antigo_memoria` no harness; bancada contra o código real |
| M-07 | `89b44eb` | métricas sem texto, correção da pessoa depois de um `lembrar`, painel "Memória" no Grafana |
| M-08 | `b4e3018` | arquitetura, pendências, harness, relatório |
| fora das histórias | PR #68 | Perplexity Decider como padrão; admissão no ledger antes de toda chamada paga |

**Correção que a #67 não cumpria:** a memória seguia ligada quando o ledger não
respondia. A #68 pôs a admissão antes e a liquidação depois, com liberação da
reserva quando não houve gasto; sem ledger, nenhuma chamada.

## Corridas resolvidas

- **Reserva presa no ledger.** Uma chamada que não gastava deixava a reserva
  aberta. Agora a reserva é liberada ao fim, e o limite do dia conta o gasto
  real.
- **Índice e `/esquecer`.** O `/esquecer` apaga o `conversations/recall.idx`
  junto com as conversas; sem isso, o que foi apagado voltaria numa busca.
- **Troca de fornecedor misturando vetores.** O índice guarda o modelo junto
  de cada vetor. Trocar de fornecedor refaz o índice em vez de comparar
  vetores de escalas diferentes.

## O que fica

- ~~**Teste do turno inteiro com o LLM mock.**~~ Escrito em 25/11:
  `test/e2e/recall_e2e_test.gleam` leva uma mensagem pelo roteador, deixa o
  porteiro disparar e confere que o que `lembrar` achou chega ao modelo no
  mesmo turno. O par dele, com a memória desligada, confere que sem memória
  nada disso aparece no que o modelo vê (I5).
- **Primeira consulta de uma pessoa:** monta o índice inteiro, ~13 s com 2.600
  mensagens, perto do tempo-limite de 15 s. Se estourar, o que já foi
  vetorizado fica salvo e a consulta seguinte termina. Vetorizar em segundo
  plano é o próximo passo.
- **Orçamento:** só o da instância, sem limite por pessoa.
- **Pergunta de correção da pessoa:** não foi medida com o Decider; o corte de
  0,5 foi herdado.
- **Rodar o Decider em casa:** descartado, porque a máquina do piloto só tem
  CPU.
