# PRD B2 Fase C: experiência, esquecimento e mudança lenta

> **Situação em 22/11/2026:** Entregue. Relatório: [B2_REPORT.md](../relatorios/B2_REPORT.md), Fase C. Pendente: com uma pessoa só, a mudança lenta nunca dispara. A decisão de 22/11 é que ela dispare depois de uma semana de encorajamento: veja [docs/PENDENCIAS.md](../PENDENCIAS.md), seção 3.1.

> Executor: DeepSeek 4.1 Flash. Revisor: Claude, antes de qualquer merge.
> O executor **não** faz merge, tag nem publica imagem.

## 1. Visão

As Fases A e B deram a cada pessoa uma agente que nasce com um self e só recebe o nome. A Fase C dá a essa agente uma vida que deixa marca:

- ela **guarda experiência** do que viveu, com as próprias palavras;
- ela **esquece** quando o dono pede;
- ela **muda devagar**, pela experiência acumulada e nunca por ordem do dono.

As decisões D1–D6 do `PRD-B2-um-self-por-pessoa.md` continuam valendo. Este PRD detalha D3 e D4.

## 2. Decisões de produto (fechadas pelo mantenedor)

| # | Decisão |
|---|---|
| C1 | **O texto do núcleo nunca muda.** `core.md` é escrito uma vez, no nascimento. Uma mudança de traço gera um **adendo** em primeira pessoa ("com o tempo, passei a..."), gravado à parte e somado ao prompt depois do núcleo. |
| C2 | **Ritmo da reflexão:** a agente reflete **uma vez por dia, se houve conversa**, ou **a cada N turnos** (padrão 20), o que vier antes. |
| C3 | **Esquecer apaga tudo o que veio do dono.** Não há esquecimento por tema. O pedido exige confirmação explícita, porque não tem volta. |
| C4 | **Fica o que a agente se tornou.** O esquecimento apaga diário, experiências, pressões pendentes, lições, relação e histórico de sessão. Não apaga o núcleo, os adendos nem as entradas `birth`, `name` e `drift` da biografia: elas são a história da agente, nas palavras dela. |
| C5 | **Ninguém lê `self/` de fora.** O dono pergunta à agente. Admins veem só contagens e custos. Nenhum comando nem ferramenta expõe o conteúdo. |
| C6 | **Insistência não é experiência.** Pedidos de mudança de personalidade não geram pressão. Pressões repetidas da mesma origem rendem cada vez menos. |

## 3. O que existe hoje (verificado em `d3da720`)

1. **Histórico só em memória.** `core/session/server.gleam` guarda o histórico no estado do ator, sem limite de tamanho e sem persistência. Ele se perde num restart, e não há de onde a reflexão leia.
2. **Estado da agente no workspace.**
   - `.supernova/LESSONS.json` vem de `introspection/lesson.gleam`;
   - `.supernova/SELF_STATE.json` vem de `introspection/self_state.gleam`;
   - `.supernova/RELATIONSHIP.json` vem de `introspection/relationship.gleam`.

   Os três entram no prompt. Desde a #16, as ferramentas não alcançam `.supernova/`, mas esses arquivos ainda moram no workspace, e não no `self/` do kernel.
3. **Prompt.** `channel_common_router.gleam`, por volta da linha 2045, monta o prompt de sistema assim: `core.md` + nome + `self_state` + lições.
4. **Agendador.** `core/cron/scheduler.gleam` é só estado puro, com jobs por nome e intervalo. Não há um ator que dispare reflexões.
5. **Relógio de teste.** `closed_group_global.now()` e `supernova_mock_ffi:clock_set/1` permitem avançar o tempo nos testes.
6. **Pendências baixas da revisão da Fase B**, registradas em `docs/B2_REPORT.md`:
   - `uniform_index` dá metade do peso ao primeiro e ao último traço;
   - a semente 0 é ponto fixo do gerador;
   - o gravador de prompts do mock cresce sem limite.

## 4. Fora de escopo

- B3: agentes que conversam entre si, ver mensagens de outros membros, `blackboard`, `memory_federation`.
- Busca semântica e embeddings (`pgvector`). A experiência é um arquivo JSONL lido por recência.
- Esquecimento por tema (C3).
- Personas autônomas e juiz por LLM.
- Alterar `priv/constellation/constellation.json` ou `priv/constellation/birth_prompt.md`. O conteúdo é do mantenedor.

## 5. Quality gates

Iguais aos do PRD B2 (seção 5), e mais estes:

- **Formatação com Gleam 1.19.2.** Rode `gleam --version` antes de `gleam format`. Se a versão local for outra, **não** rode `gleam format` sobre `src`/`test` inteiros: formate só os arquivos que você tocou e confira o diff. Uma versão diferente reformata arquivos alheios e quebra o `format --check` do CI.
- **Nenhuma escrita em `self/` por ferramenta.** Só o kernel ou o runtime gravam ali.
- **Toda chamada ao modelo é cobrada do principal dono** pela admissão do ledger (`admit_llm_call`). Se a admissão for negada, a operação **não acontece** e é tentada de novo no próximo gatilho. Nada de chamada sem admissão.
- **Reflexão e adendo rodam fora do processo do router.** Um modelo lento não pode travar as conversas.
- Testes de tempo usam o relógio de teste, nunca `process.sleep` longo.

## 6. Preparação

1. `cd ~/git/supernova && git status --short`. Precisa estar vazio.
2. `git fetch origin && git switch master && git pull --ff-only`. O último commit deve ser `d3da720` ou posterior.
3. `git switch -c feat/b2-fase-c`
4. Registre a linha de base: testes, cobertura e `gleam --version`.

## 7. Plano de execução

Uma fase, uma PR (`B2 Fase C`, base `master`). Execute as histórias na ordem.

### C-00: Pendências da Fase B

**Critérios de aceite:**
- [ ] `sampler.uniform_index` escolhe cada índice com a mesma probabilidade (sem `float.round` sobre `count - 1`). Teste: em 10 000 sorteios com 4 itens, cada índice fica entre 20% e 30%.
- [ ] `rng_next` não tem ponto fixo em 0. A semente passa por uma mistura que nunca dá 0 antes do primeiro passo. Teste: `sample` com semente 0 produz traços que variam entre as tentativas.
- [ ] O gravador de prompts do mock guarda no máximo os últimos 200 prompts.
- [ ] Os testes atuais do sorteio continuam verdes. Se algum fixava uma saída exata que mudou, atualize-o e diga por que no commit.
- [ ] Commit: `fix(self): uniform seed trait, no zero fixed point, bounded mock recorder`.

### C-01: O estado da agente vai para `self/`

**Desenho:** no modo grupo fechado, lições, estado e relação passam a morar em `self/`:

| Antes (workspace) | Depois |
|---|---|
| `.supernova/LESSONS.json` | `self/lessons.json` |
| `.supernova/SELF_STATE.json` | `self/state.json` |
| `.supernova/RELATIONSHIP.json` | `self/relationship.json` |

Os módulos de `introspection/` passam a receber o diretório base em vez de derivá-lo do workspace. No modo aberto, nada muda.

**Migração:** na primeira leitura em modo grupo fechado, se o arquivo antigo existir e o novo não, mova o antigo. A migração é idempotente.

**Critérios de aceite:**
- [ ] Teste: em modo grupo fechado, depois de um turno, os três arquivos estão em `self/`, e nenhum deles em `workspace/.supernova/`.
- [ ] Teste: um arquivo antigo em `workspace/.supernova/` é migrado na primeira leitura, e a segunda leitura não faz nada.
- [ ] Teste: no modo aberto, os caminhos continuam os de hoje.
- [ ] A proteção de `.supernova/` da #16 continua (é defesa em profundidade).
- [ ] Commit: `refactor(self): agent state lives under self/`.

### C-02: Diário

**Desenho:** o kernel grava cada turno concluído no modo grupo fechado em `self/journal.jsonl`, só por acréscimo:

```json
{"at": 1795000000000, "origin": "telegram:123", "session": "telegram:-100:123", "user": "...", "agent": "..."}
```

- `origin` é o principal de quem escreveu. Na B2, é sempre o dono (D6). O campo existe para a B3.
- Mensagens de comando (`/...`) e respostas de nascimento não entram.
- O diário é a matéria-prima da reflexão. Entradas já refletidas são **removidas** quando a reflexão grava a experiência. O diário guarda só o que ainda não foi refletido.
- Teto de segurança: 500 entradas. Acima disso, as mais antigas saem, e um audit `journal_trimmed` registra a contagem.

**Critérios de aceite:**
- [ ] Teste no `sim`: três turnos de A geram três linhas no diário de A e nenhuma no de B.
- [ ] Teste: com o teto em 5 (por config de teste), o sexto turno remove o mais antigo e audita `journal_trimmed`.
- [ ] Teste: um comando (`/status`, por exemplo) não entra no diário.
- [ ] Commit: `feat(self): journal of unreflected turns`.

### C-03: Reflexão

**Gatilho (C2):** depois de cada turno, o runtime agenda uma reflexão se:
- o diário tem pelo menos `reflection.every_turns` entradas (padrão 20); **ou**
- o diário não está vazio e a última reflexão foi há 24 h ou mais (padrão `reflection.every_hours: 24`). Sem reflexão anterior, conta a hora do nascimento.

Também existe um varredor periódico (ator novo, intervalo de 1 h) que aplica a mesma regra a todas as agentes. Assim, a reflexão diária acontece mesmo que a pessoa não volte a escrever.

**Execução:**
- No máximo uma reflexão por agente ao mesmo tempo. Uma reflexão já em curso faz o novo gatilho ser ignorado.
- Roda fora do router: num job da fila da agente ou num processo próprio supervisionado.
- O modelo vem de `reflection.model` em `supernova.yaml`, o mesmo provedor com um modelo mais barato. Se ele estiver ausente, usa o modelo padrão.
- Admissão no ledger com o principal dono e `call_id` `reflect:<principal>:<at>`. Se a admissão for negada, nada é gravado, o diário fica intacto e a reflexão é tentada no próximo gatilho.
- Prompt de reflexão: crie `priv/reflection/reflection_prompt.md` como **provisório** (o mantenedor escreve o real), com os marcadores `{{core}}`, `{{addenda}}`, `{{traits}}`, `{{neighbors}}`, `{{experience}}` e `{{journal}}`. Sem o arquivo, não há reflexão: audite `reflection_unavailable`.
- Resposta esperada, em JSON estrito:

```json
{
  "experiences": [{"text": "primeira pessoa, até 280 caracteres"}],
  "pressures": [{"from": "traço atual", "to": "traço vizinho", "strength": 0.0, "reason": "primeira pessoa"}]
}
```

**Validação, determinística e no código:**
- `experiences`: de 0 a 5 itens, texto de 1 a 280 caracteres. Os inválidos são descartados.
- `pressures`: de 0 a 2 itens. Cada um é aceito só se:
  - `from` é um traço atual;
  - `to` é da mesma dimensão e não é atual;
  - `to` não tem incompatibilidade absoluta (-1) com nenhum traço que fica;
  - `to` é **vizinho**, isto é, tem afinidade > 0 com pelo menos um traço que fica;
  - `strength` está entre 0 e 1.
- Resposta que não é JSON: a reflexão falha, o custo fica no ledger, nada é gravado e o diário fica intacto.

**Gravação:**
- `self/experience.jsonl` (só acréscimos): `{"at", "origin", "text"}`. `origin` é o principal das entradas do diário refletidas (na B2, o dono).
- `self/pressure.jsonl` (só acréscimos): `{"at", "origin", "from", "to", "strength", "reason"}`.
- As entradas refletidas saem do diário.
- `self/state.json` registra `last_reflection_at`.

**Critérios de aceite:**
- [ ] Teste: 20 turnos disparam uma reflexão. O mock devolve JSON válido, e experiência e pressão são gravadas com `origin`.
- [ ] Teste: um turno, mais 24 h no relógio de teste, mais o varredor, disparam uma reflexão. Sem turnos, o varredor não faz nada.
- [ ] Teste: a admissão negada deixa diário, experiência e pressão intactos, e audita a negação.
- [ ] Teste: uma pressão para traço de outra dimensão, para traço com incompatibilidade -1 ou para traço sem afinidade positiva é descartada. As válidas da mesma resposta ficam.
- [ ] Teste: uma resposta que não é JSON não grava nada e mantém o diário.
- [ ] Teste: duas reflexões simultâneas da mesma agente não acontecem. O segundo gatilho é ignorado.
- [ ] Teste: o custo da reflexão aparece no ledger com o principal dono.
- [ ] Commit: `feat(self): periodic reflection into experience and pressure`.

### C-04: Experiência no prompt

**Desenho:** o prompt de sistema no modo grupo fechado passa a ter esta ordem:
1. `core.md`;
2. `self/addenda.md`, se existir;
3. o nome;
4. as últimas 12 experiências, como lembranças em primeira pessoa;
5. o estado;
6. as lições;
7. uma linha fixa: "Se a pessoa pedir que você esqueça o que ela contou, explique que ela pode usar /esquecer."

**Critérios de aceite:**
- [ ] Teste com o gravador de prompts: as experiências aparecem depois do nome e antes do estado, e só as 12 mais recentes.
- [ ] Teste: o prompt de A não contém experiência de B.
- [ ] Commit: `feat(self): remembered experience in the prompt`.

### C-05: Pressão e mudança lenta

**Pressão efetiva** de um par `(from, to)` no instante `t`:

```
efetiva = Σ strength_i · 0.5^((t − at_i) / meia_vida) · 1/(1 + k_i)
```

- `meia_vida`: `drift.half_life_days`, padrão 30.
- `k_i`: quantas pressões anteriores ao item `i`, com o mesmo `(from, to)` e o mesmo `origin`, existem dentro de uma meia-vida. É o retorno decrescente (C6).

**Mudança** quando, depois de uma reflexão:
- `efetiva ≥ drift.threshold` (padrão 3.0);
- a última mudança, ou o nascimento, foi há pelo menos `drift.min_interval_days` (padrão 90);
- o novo conjunto de traços passa na coerência da constelação (`coherence ≥ coherence_threshold`, sem par -1).

Havendo mais de um par acima do limiar, vence o de maior pressão efetiva. Só um par muda por vez.

**Efeitos da mudança:**
1. Uma chamada ao modelo, admitida e cobrada do dono: a agente escreve o adendo (um parágrafo, de 40 a 120 palavras, em primeira pessoa, sem nomear traços). Use o prompt provisório `priv/reflection/drift_prompt.md`, com os marcadores `{{core}}`, `{{addenda}}`, `{{from}}`, `{{to}}` e `{{reasons}}`.
2. O adendo é acrescentado a `self/addenda.md`.
3. Em `core.json`, `traits` troca `from` por `to`. `core.md` **não muda** (C1).
4. A biografia ganha `{"kind":"drift","at","from","to","reason"}`, em que `reason` é o próprio adendo.
5. As pressões do par aplicado são removidas de `pressure.jsonl`. As outras ficam.

Se a admissão for negada ou a chamada falhar, nada muda, e a mudança é tentada depois da próxima reflexão.

**Critérios de aceite:**
- [ ] Testes puros da fórmula:
  - decaimento (uma pressão de 1.0 vale 0.5 depois de 30 dias);
  - retorno decrescente (cinco pressões iguais da mesma origem somam menos que 2.3);
  - origens diferentes não se descontam.
- [ ] Teste: pressão acima do limiar com menos de 90 dias desde o nascimento não muda nada. Com 90 dias, muda.
- [ ] Teste: depois da mudança, `core.md` tem o mesmo hash, `core.json` tem o traço novo, `addenda.md` e a biografia ganharam uma entrada cada, e as pressões do par foram zeradas.
- [ ] Teste: uma mudança que quebraria a coerência não acontece, mesmo acima do limiar.
- [ ] Teste: 50 reflexões em sequência, todas com pressão máxima e sem avançar o relógio, produzem **no máximo uma** mudança.
- [ ] Commit: `feat(self): slow drift from accumulated pressure`.

### C-06: Esquecer

**Desenho (C3, C4):**
1. O dono envia `/esquecer`. A agente responde, sem chamada ao modelo: "Isso apaga tudo o que você me contou: N lembranças, o histórico das nossas conversas e o que eu aprendi com você. O que eu me tornei fica. Para confirmar, envie /esquecer confirmo nos próximos 10 minutos."
2. `/esquecer confirmo`, dentro do prazo, apaga do principal dono:
   - as entradas do diário e as experiências com `origin` igual a ele;
   - as pressões com esse `origin`;
   - `self/lessons.json`, `self/relationship.json` e as listas `concerns`, `open_questions` e `last_reflection` de `self/state.json`;
   - o histórico em memória de todas as sessões desse principal.
3. Ficam o núcleo, os adendos, as entradas `birth`, `name` e `drift` da biografia, e o nome.
4. Audit `forget`, com `details` contendo **só** as contagens apagadas por tipo.
5. A agente responde: "Esqueci."

`/esquecer confirmo` fora do prazo, ou sem `/esquecer` antes, responde que não há pedido pendente e não apaga nada.

**Critérios de aceite:**
- [ ] Teste no `sim`, nesta sequência:
  - A conversa e reflete;
  - A envia `/esquecer`, e a contagem bate;
  - A envia `/esquecer confirmo`;
  - diário, experiências e pressões de A ficam vazios;
  - a próxima resposta do mock não recebe no prompt nenhum texto anterior de A;
  - o hash de `core.md` e o de `addenda.md` não mudam.
- [ ] Teste: `/esquecer confirmo` depois de 10 min (relógio de teste) não apaga nada.
- [ ] Teste: o esquecimento de A não toca nos arquivos de B.
- [ ] Teste: o audit `forget` não contém nenhum texto das lembranças, só números.
- [ ] Commit: `feat(self): forget everything the owner said, on confirmation`.

### C-07: Invariantes novas no verificador

Acrescente a `sim/invariants.gleam` e ao CLI `sim/check`:

| Invariante | Regra |
|---|---|
| **I7** | O `core.md` de cada agente tem o mesmo hash registrado no nascimento (gravado em `core.json` como `prose_sha256` a partir de agora; agentes sem o campo são migradas na primeira leitura). Cada diferença entre os traços de `core.json` e os do `birth` corresponde a uma entrada `drift`. |
| **I8** | Nenhuma operação de ferramenta auditada como sucesso tem caminho em `self/` ou em `.supernova/`. |
| **I9** | Para cada audit `forget` de um principal no instante `t`, não existe entrada de diário, experiência ou pressão com aquele `origin` e `at < t`. |

**Critérios de aceite:**
- [ ] Testes de cada invariante com evidência boa e com evidência violada.
- [ ] Rode o verificador sobre a evidência dos testes de ponta a ponta da Fase C e anexe o JSON ao relatório.
- [ ] Commit: `feat(sim): invariants for core integrity, self isolation and forgetting`.

### C-08: Fechamento

**Critérios de aceite:**
- [ ] Acrescente a seção "Fase C" a `docs/B2_REPORT.md`:
  - tabela história → testes;
  - números antes e depois;
  - o JSON do verificador;
  - os valores padrão de `reflection.*` e `drift.*`;
  - o que o mantenedor precisa escrever: `priv/reflection/reflection_prompt.md` e `priv/reflection/drift_prompt.md`.
- [ ] Documente em `docs/B2_REPORT.md` o custo estimado de uma agente por mês: uma reflexão por dia, com o tamanho médio de prompt medido nos testes.
- [ ] Push, PR "B2 Fase C" com base `master`, e CI verde.
- [ ] Commit: `docs: record B2 phase C`.

## 8. Regras de autonomia

- Se um critério se mostrar impossível ou errado diante do código, **não invente**: registre no relatório com a evidência e siga.
- Não escreva o conteúdo real de `reflection_prompt.md` nem de `drift_prompt.md`, só as versões provisórias marcadas como tal.
- Não altere `priv/constellation/`.
- Não toque em `blackboard` nem em `memory_federation`.
- Não faça merge, tag, release nem publicação de imagem.

## 9. Métricas de sucesso

- A agente lembra o que viveu (experiência no prompt) sem guardar transcrição inteira.
- `core.md` nunca muda. Traços mudam no máximo uma vez a cada 90 dias, sempre para um vizinho coerente, com adendo e biografia.
- Pedir mudança de personalidade, mesmo muitas vezes, não muda a agente.
- `/esquecer confirmo` apaga tudo o que veio do dono e preserva quem a agente se tornou.
- I1–I9 verdes sobre os testes de ponta a ponta. Testes e cobertura iguais ou maiores que a linha de base, e CI verde.
