# PRD-N: relatório final

[PRD](../prd/PRD-N-nome.md) · PR #22 e #23 · 19/11

## Resumo

O primeiro teste real do harness mostrou um laço:

```
agente: <núcleo> ... Como você quer me chamar?
bia:    Bia. A não ser que você prefira outro nome — nesse caso, diga qual e por quê.
agente: Como você quer me chamar?
```

`birth.step` só aceitava a mensagem inteira como nome quando ela passava em
`core.valid_name`, de 1 a 40 caracteres, com letra ASCII e sem `/`. Qualquer
resposta natural ("pode te chamar de Luna", "que tal Bia?") caía no laço sem
explicação. Hoje o fluxo é outro:

- **A pergunta** é "Que nome você quer me dar?", e não mais "Como você quer me
  chamar?", que se lia como um pedido do nome da pessoa.
- **Uma palavra só** que passe em `valid_name` vira candidata sem chamar o
  modelo.
- **Qualquer outra resposta** vai ao modelo, com o prompt de
  `priv/constellation/name_prompt.md`, que devolve `{"name": "..."}` ou
  `{"name": null}`. A chamada é admitida no ledger e cobrada do dono, com
  `call_id` `name:<principal>:<at>` e `purpose: "name"` no `prompt_log`.
- **Antes de gravar, a agente confirma:** "Então meu nome é Bia? Responda sim
  ou não." O candidato fica em `self/name_pending.json` com a hora, e vale 10
  minutos.
- **A confirmação não usa modelo.** Depois de `trim`, minúsculas e remoção da
  pontuação final, a resposta é comparada com uma lista fixa de afirmações
  (`sim`, `s`, `isso`, `pode`, `claro`, `ok`, `é`, `perfeito`, `beleza`, `👍`
  e outras) e de negações (`não`, `nao`, `n`, `não é`, `outro`, `nope`).
- **O nome confirmado continua passando por `core.valid_name`.** O modelo
  propõe, o kernel valida.

## Medição final

Esta PRD não tem bancada própria: o que ela conserta é um laço, não um número.
O único valor medido é a suíte, na #22.

| | Valor |
|---|---|
| Cobertura de linha | **77,95%** (limiar do gate na época: 75%) |
| Testes | `Tests: ok` |
| `gleam format --check`, `gleam build --warnings-as-errors` | ok |

O antes e o depois do harness não foram registrados como medida: o laço foi
visto numa execução real, e o que existe é o teste de ponta a ponta que o
substitui, `sim_naming_end_to_end_test`.

## Critérios da PRD (seções 3 e 7)

| Critério | Resultado |
|---|---|
| Pergunta nova, sem tocar no bootstrap legado do modo aberto nem nos fixtures | **Atingido** (`62efe78`). |
| Candidato pendente em `self/name_pending.json`, com validade de 10 min | **Atingido** (`bdbc005`); `pending_ttl_ms = 600_000`, e o teste usa o relógio de teste. |
| Afirmação e negação decididas sem modelo, com caixa, espaços e `.!` | **Atingido**; cada palavra da lista tem teste. |
| "sim, mas prefiro Ana" não confirma o pendente | **Atingido**: não é afirmação exata, então a extração roda e "Ana" passa a ser o novo candidato. |
| `name_pending.json` apagado depois de aceito ou recusado | **Atingido**, com teste. |
| Extração pelo modelo, com o prompt da seção 4 e JSON estrito | **Atingido** (`e34bf68`); a cerca de código é removida como na reflexão. |
| Sem `name_prompt.md` (`SUPERNOVA_NAME_PROMPT_PATH` inexistente), a resposta é "Não entendi..." | **Atingido**: falha fechada, nada é gravado. |
| Nome de 60 caracteres vindo do modelo | **Recusado** por `valid_name` e tratado como falha de extração, não como nome ausente. |
| Admissão negada | **Atingido**: "Não entendi..." e nada gravado. |
| Chamada no ledger, cobrada do dono, e no `prompt_log` com `purpose: "name"` | **Atingido** em `test/e2e/sim_e2e_test.gleam`. |
| Ponta a ponta: "oi" → pergunta → "pode te chamar de Luna" → confirmação → "sim" → nome aceito | **Atingido** (`48b1dad`); depois disso um turno normal entra no diário. A fala de aceitação era "Prazer, Luna." e virou "Luna, então. Prazer!" no `06cd9f8`. |
| Cenários provisórios do harness respondendo à confirmação | **Atingido**: um `say` do nome e um `say` "sim" antes das conversas. |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| N-01 | `62efe78` | a pergunta passa a ser "Que nome você quer me dar?" |
| N-02 | `bdbc005` | candidato pendente e confirmação antes de gravar |
| N-03 | `e34bf68` | o modelo extrai o nome de uma resposta natural |
| N-04 | `48b1dad` | ponta a ponta e fechamento |

Depois do merge, a PR #23 corrigiu o que a primeira bateria real mostrou:

| Commit | O que corrigiu |
|---|---|
| `42feefa` | extração que falha nunca confirma o pendente; o nome de substituição é extraído uma vez; Hangul Jamo conta como CJK |
| `fa9856b` | nome de substituição inválido também nunca confirma o pendente |
| `06cd9f8` | a agente toma o nome como seu ("Clara, então. Prazer!"), capitalizado |

## Corridas resolvidas

- **Resposta livre depois da confirmação.** Pessoas respondem "Sim, Vera.
  Fechado." ou "sim kkk líquen combina". Exigir um "sim" exato dava laço, o
  mesmo defeito que a PRD veio corrigir, um passo adiante. Agora a resposta
  livre é resolvida em três casos: o mesmo nome outra vez aceita, outro nome
  vira o novo candidato, e uma resposta sem nome que abre com afirmação
  aceita o pendente.
- **Falha de extração tratada como "não deu nome".** Se a extração falhava, a
  resposta podia confirmar o candidato errado. Hoje falha de extração e nome
  inválido são erros, não ausências, e o pendente continua pendente.
- **Pendente expirado.** Depois de 10 minutos o arquivo é ignorado e apagado, e
  a mensagem é tratada como uma resposta de nome nova, em vez de confirmar um
  nome de dez minutos atrás.

## O que fica

- **`core.valid_name` continua restritivo:** de 1 a 40 caracteres, com letra
  ASCII e sem `/`. Nome com acento, hífen ou emoji depende dessa regra, e ela
  não mudou nesta PRD.
- **Uma chamada de LLM por resposta natural de nome.** Só a palavra única
  dispensa o modelo. Quem responde frases longas paga a extração.
- **O prompt é conteúdo do mantenedor.** Está em
  `priv/constellation/name_prompt.md` e não deve ser reescrito por executor.
