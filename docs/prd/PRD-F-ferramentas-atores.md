[PRD]
# PRD F: Ferramentas como atores, e em segundo plano

> **Situação em 23/11/2026:** proposta. Faltam as decisões D1–D7 da seção 5.
> A fase A não depende de outra PRD. A fase B depende da P-03 da
> [PRD-P](PRD-P-paralelismo.md), o processo da agente.

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem de cada fase**. Cada história termina com os
> quality gates verdes e um commit próprio. Se a sessão for interrompida,
> retome pela primeira história sem commit, conferindo `git log --oneline`
> contra os títulos de commit.

## 1. Contexto

### 1.1 Como uma ferramenta roda hoje

```
turno (processo do turno)
  └─ executor ──► gateway: AuthorizeTool → ClaimTool (cobra o orçamento)
                 └─ executa a ferramenta AQUI, no processo do turno
                 └─ gateway: ToolCompleted (ledger, audit)
```

- **O gateway** (`core/syscall/actor`) autoriza e cobra: capability, política
  de workspace e orçamento de ferramentas. A execução acontece **no processo de
  quem chamou**.
- **As chamadas de uma mesma rodada** rodam ao mesmo tempo desde a #62, até 8
  de cada vez. Mesmo assim, cada chamada continua sem prazo.
- **Prazo próprio** só existe em algumas ferramentas: o `computador` (60 s,
  até 300 s) e o `browser`. As demais esperam o que for preciso.

### 1.2 O que isso causa

- **Uma ferramenta que não responde prende o turno.** O único limite está na
  fila do chat: depois de 5 min (`turn_hard_timeout_ms`), ela desiste e a
  pessoa recebe "Streaming timed out".
- **Os processos ficam vivos.** O processo do turno e os das ferramentas
  foram criados sem link. Quando a fila desiste, ninguém os mata, e eles se
  acumulam.
- **Os limites não distinguem as ferramentas.** Um `web` travado ocupa o
  mesmo lugar que uma `buscar_conversa`. Não há limite por ferramenta nem por
  agente, e não há como ver a fila de cada ferramenta.
- **A agente não pode deixar de esperar.** Toda ferramenta prende o turno até
  terminar, então uma tarefa de minutos, como um levantamento no `computador`
  ou uma leitura longa na web, é impossível ou estoura o prazo.

### 1.3 O que já existe para a fase B

- **A agenda** já entrega uma mensagem sintética (`[Agenda] …`) no chat da
  pessoa (`registry.inject`). A agente responde pelo caminho normal, com gate,
  histórico e época do `/esquecer`.
- **O histórico** guarda chamada e resultado de cada ferramenta (#59).

Um resultado que chega depois pode seguir exatamente esse caminho.

## 2. Objetivo

- **Fase A.** Cada ferramenta é um ator. Cada chamada é um processo
  supervisionado, com prazo, cancelamento, limite por ferramenta e por agente,
  e medição. Uma ferramenta nunca prende o turno além do seu prazo, e nada
  fica vivo sem alguém esperando.
- **Fase B.** A agente pode pedir que uma ferramenta rode **em segundo
  plano**: responde à pessoa na hora e recebe o resultado depois, como uma
  mensagem nova, pelo caminho da agenda.

O protocolo com o modelo continua o nativo das APIs:
- várias chamadas na mesma resposta rodam juntas;
- a próxima rodada vem depois do resultado.

A única coisa nova que o modelo vê é a ferramenta `tarefa`, na fase B.

## 3. Fora de escopo

- **`para_cada(ferramenta, lista)`** e grafos de dependência numa rodada. O
  protocolo nativo já cobre paralelo e sequência. Só entram com um caso real
  de N grande, medido no harness.
- **Retomar uma tarefa interrompida por restart.** As ferramentas não são
  idempotentes. A tarefa interrompida é **avisada**, não refeita (D6).
- **Ferramentas novas.**

## 4. Quality gates

Os mesmos da [PRD-P](PRD-P-paralelismo.md#4-quality-gates): formatação, build
sem warnings, testes, cobertura que não cai e `git status` limpo. Mais:

- Um teste de **processos vivos**: depois de cada cenário de cancelamento,
  nenhum processo da chamada continua vivo. Confira pelos pids monitorados,
  nunca contando todos os processos da VM.
- A partir da F-03, uma rodada do teste de estresse com a mistura de
  ferramentas lentas (`--tool-mix`, F-01), sem regressão de turnos/s contra a
  linha de base da F-00.
- **Regras** da PRD-P: só o dono recebe num subject; nada de `sleep` fixo para
  estabelecer estado; TDD com a falha inicial registrada; sem rede ou tokens
  reais.

## 5. Decisões do mantenedor

Cada uma tem uma recomendação. Se a decisão não vier, o executor segue a
recomendação.

- **D1. Prazo padrão de uma ferramenta.** Recomendação: **120 s**. A
  ferramenta que declara prazo próprio recebe o dela mais 15 s de folga. O
  `computador`, por exemplo, fica em até 315 s.
- **D2. Limites.** Recomendação:

  | Ferramenta | Por agente | Na instância |
  |---|---|---|
  | `computador` | 2 | 8 |
  | `browser`, `web` | 4 | 32 |
  | as demais | 8 | 64 |

  Uma chamada sem vaga espera até 10 s. Depois disso, o modelo recebe "a
  ferramenta está ocupada; tente de novo ou siga sem ela".
- **D3. Quais ferramentas podem rodar em segundo plano.** Recomendação:
  `computador`, `browser`, `web` e `github`. As ferramentas da própria agente
  (`file_system`, `agenda`, `buscar_conversa`, `canvas`) não podem: são
  rápidas, e o resultado só serve dentro do turno.
- **D4. Tarefas em segundo plano por agente.** Recomendação: **no máximo 3
  ao mesmo tempo**, cada uma com prazo de até 30 min.
- **D5. Para onde vai o resultado.** Recomendação: **para o chat em que a
  tarefa foi pedida**, porque o que foi pedido num grupo volta ao grupo, e o
  privado, ao privado. A resposta passa pelo gate e conta no orçamento da
  pessoa, como a da agenda. Se a pessoa não tiver orçamento na hora, o
  resultado fica guardado e é entregue junto com a próxima mensagem dela.
- **D6. Restart com tarefa em andamento.** Recomendação: a tarefa morre com
  o processo. No boot, a agente recebe "[Tarefa] a tarefa X foi interrompida
  pelo reinício" e avisa a pessoa. A tarefa não é refeita.

- **D7. Isolamento com Bubblewrap.** As ferramentas que rodam processos no
  host (`safe_shell`, `process`, `git_inspect`, `github` via `gh`) hoje
  dependem só da validação de argumentos. Com o `bwrap` (já instalado no
  host, 0.9.0), cada chamada roda num namespace isolado:
  - só o workspace da pessoa montado, para escrita, e o necessário para leitura;
  - `/proc` e `/dev` mínimos;
  - rede desligada quando a ferramenta não precisa;
  - `--die-with-parent`, para que matar o processo da chamada (F-02) mate a
    árvore inteira.

  Recomendação: entra, como F-08, para essas quatro ferramentas, atrás da
  configuração `tools.sandbox: bwrap | none`, com padrão `bwrap` quando o
  executável existir e aviso no log quando não existir. O `computador`
  continua no gVisor.

`/esquecer` **cancela** as tarefas em andamento da pessoa e descarta os
resultados que ainda não foram entregues. Isso não é decisão, é invariante
(I8).

## 6. Desenho

### 6.1 Fase A: o executor de ferramentas

Um módulo novo, `supernova/tools/runner`, com:

- **Ficha de cada ferramenta** (`ToolSpec`): nome, prazo, limite por agente,
  limite na instância e se pode rodar em segundo plano. As fichas ficam junto
  da definição de cada ferramenta (`tool_dispatch`), e a configuração pode
  mudar os números.
- **Um supervisor por ferramenta,** com `trap_exit`, nos moldes do
  supervisor de sessões depois da #61. Ele mantém a contagem de chamadas em
  andamento, por agente e no total, numa tabela ETS com `update_counter`.
  Assim, conferir a vaga não passa por um processo.
- **Uma chamada vira um processo filho desse supervisor.**
  - O executor do turno passa autorização, ficha e argumentos.
  - O filho executa e responde ao turno.
  - O supervisor faz valer o prazo: no estouro, mata o filho e responde
    "ERROR: <ferramenta> não respondeu em N s".
- **Cancelamento.** O supervisor monitora o processo do turno. Se o turno
  morre, as chamadas dele são mortas. A fila do chat, ao desistir de um turno
  (5 min), mata o processo do turno. Hoje ela só para de esperar.
- **O gateway** continua sendo o único a autorizar e cobrar. O `ToolCompleted`
  passa a levar também o desfecho `timeout` e `cancelado`, para o ledger e o
  audit.
- **Uma chamada sozinha** também vai para o supervisor: é o único jeito de
  ter prazo e cancelamento. O custo é um processo, na casa dos
  microssegundos.
- **O limite global de 8 da #62** sai: o que limita passam a ser as vagas de
  cada ferramenta.
- **Telemetria:** `tool_running`, `tool_waiting`, `tool_timeouts_total` e
  `tool_cancelled_total` por ferramenta. Entram no painel do Grafana.

### 6.2 Fase B: `tarefa`

**A ferramenta que o modelo vê:**

```
tarefa(acao: "iniciar", ferramenta, argumentos, motivo)
  → "Tarefa 7 iniciada. Avise sua pessoa; o resultado chega como mensagem."
tarefa(acao: "listar")   → as tarefas em andamento e as já concluídas que ainda não foram entregues
tarefa(acao: "cancelar", id)
```

**Dono.** As tarefas pertencem ao **processo da agente** (PRD-P, P-02). Ele
inicia a chamada no executor da fase A, com o prazo de tarefa (D4), e
registra a tarefa em disco em `agents/<pessoa>/self/tasks.jsonl`, com
pedido, chat de origem, início e estado.

**Entrega.** Quando o resultado chega:
1. A agente grava o resultado e manda pelo `registry.inject` uma mensagem
   sintética ao chat de origem:
   `[Tarefa] A tarefa 7 (<motivo>), que você iniciou às HH:MM, terminou: <resultado, cortado como na #59>. Sua pessoa não escreveu agora. Conte a ela o resultado.`
2. Essa mensagem segue o caminho da agenda: fila do chat, gate, turno,
   histórico.
3. O resultado entra no histórico como consulta (formato da #59), e a
   agente pode citá-lo depois.

**Esquecimento.** O `/esquecer` da pessoa, que pela PRD-P já passa pelo
processo da agente, cancela as tarefas, apaga o `tasks.jsonl` e descarta as
entregas pendentes. Uma entrega que já estava a caminho é descartada pela
época do `/esquecer`, como na agenda.

**Restart (D6).** No boot, a agente que tem tarefas sem resultado no
`tasks.jsonl` marca cada uma como interrompida e entrega uma mensagem
`[Tarefa] … foi interrompida pelo reinício`.

### 6.3 Relação com a PRD-P

As duas PRDs mexem em partes diferentes:
- a **PRD-P**, no roteador e no estado da agente;
- a **fase A**, no executor, no gateway e nas ferramentas.

Por isso podem andar em paralelo, cada uma na sua branch. A **fase B** depende
da P-03, porque o processo da agente precisa existir, junto com o `/esquecer`
serializado por agente, para cancelar tarefas com segurança.

```
PRD-P:  P-00 → P-01 → P-02 → P-03 → P-04 → P-05 → P-06 → P-07
PRD-F:  F-00 → F-01 → F-02 → F-03 → F-04 ─┐   (F-08 a qualquer momento depois da F-02)
                                   (P-03) ─┴→ F-05 → F-06 → F-07
```

## 7. Invariantes

Testados antes da mudança que os afeta:

- **I1 – Prazo.** Uma chamada que não responde vira erro em no máximo o prazo
  da ferramenta mais 1 s. O turno continua e responde.
- **I2 – Nada vivo sem dono.** Turno morto ou abandonado implica chamadas
  mortas. Tarefa cancelada implica chamada morta.
- **I3 – Uma cobrança.** Cada chamada é cobrada uma vez só, inclusive com
  timeout, cancelamento ou ferramenta que quebra. Ledger e audit registram o
  desfecho real.
- **I4 – Ordem dos resultados.** Na mesma rodada, os resultados voltam na
  ordem das chamadas, como hoje.
- **I5 – Isolamento entre ferramentas.** Uma ferramenta lotada ou travada não
  atrasa outra, nem a mesma ferramenta de outra agente além do limite
  global.
- **I6 – A tarefa é da pessoa.** O resultado de uma tarefa só é entregue no
  chat de origem, com o principal de quem pediu. Uma tarefa nunca vê nem
  entrega nada de outra pessoa.
- **I7 – Entrega uma vez.** O resultado de uma tarefa é entregue exatamente
  uma vez, mesmo com restart entre a conclusão e a entrega. É gravado antes de
  ser entregue e marcado depois, como a fila durável.
- **I8 – Esquecer cancela.** Depois do `/esquecer`, nenhuma tarefa da pessoa
  continua rodando, e nenhum resultado dela é entregue.

## 8. Histórias

### Fase A

#### F-00: Inventário e linha de base

Monte em `docs/relatorios/PRD-F-base.md` uma tabela das ferramentas:
- prazo próprio, se houver;
- tempo típico;
- efeitos colaterais (lê, escreve, rede, processo externo);
- se pode rodar em paralelo consigo mesma.

Rode o estresse (seção 4 da PRD-P) e registre a linha de base.

- Commit: `docs(prd-f): inventário das ferramentas e linha de base`.

#### F-01: Ferramentas de mentira e invariantes

- **Ferramentas de teste.** Entram só no mock e nos testes, nunca no
  `builtin_tools` de produção:
  - `lenta(ms)`;
  - `trava()`, que nunca responde;
  - `explode()`, que quebra.
- **Marcas do mock:** `[mock-lenta N]`, `[mock-trava]` e `[mock-varias N]`
  (N chamadas na mesma rodada).
- **Estresse:** a opção `--tool-mix` mistura essas ferramentas na carga.
- **Testes de I1 a I5** contra o código atual. I1 e I2 falham hoje: entram
  marcados para pular, com a falha registrada no commit.
- Commit: `test(prd-f): ferramentas de mentira e invariantes`.

#### F-02: O executor de ferramentas

Crie o `tools/runner`: fichas, um supervisor por ferramenta, prazo e
cancelamento pelo monitor do turno (seção 6.1). O executor passa a usá-lo para
toda chamada.

**Aceite:**
- [ ] I1, I2, I3 e I4 passam.
- [ ] `ToolCompleted` registra `timeout` e `cancelado`.
- [ ] Commit: `feat(tools): cada chamada de ferramenta é um processo supervisionado com prazo`.

#### F-03: Limites por ferramenta e por agente

Vagas na ETS (D2) e espera de até 10 s por uma vaga. Sai o limite global de 8.

**Aceite:**
- [ ] I5 passa.
- [ ] Um teste com 10 chamadas de `computador` de uma mesma agente mostra no
      máximo 2 rodando ao mesmo tempo.
- [ ] Estresse com `--tool-mix` sem regressão.
- [ ] Commit: `feat(tools): vagas por ferramenta e por agente`.

#### F-04: A fila do chat encerra o turno abandonado

Ao desistir de um turno (`turn_hard_timeout_ms`), a fila do chat mata o
processo do turno, e as chamadas dele morrem pela F-02. Entra também a
telemetria da seção 6.1 e o painel.

**Aceite:**
- [ ] Teste: um turno com `trava()` e prazo de ferramenta maior que o da
      fila. A fila desiste, e nenhum processo do turno ou da chamada continua
      vivo.
- [ ] Commit: `fix(channel): turno abandonado não fica rodando`.

#### F-08: Isolamento com Bubblewrap (D7)

Execute os processos externos de `safe_shell`, `process`, `git_inspect` e
`github` dentro do `bwrap`, com o perfil da D7. O perfil é montado por uma
função pura, testável sem executar nada. A fase A já mata o processo da
chamada, e `--die-with-parent` leva a árvore junto.

**Aceite:**
- [ ] O perfil é uma função pura de (ferramenta, workspace, precisa de rede)
      para a lista de argumentos do `bwrap`, com testes de tabela.
- [ ] Teste: dentro do sandbox, ler um arquivo fora do workspace falha; ler e
      escrever dentro dele funciona. Usa só comandos inofensivos (`cat`,
      `ls`) em diretórios temporários do teste, **nunca** um comando
      destrutivo.
- [ ] Teste: matar o processo da chamada mata o filho que roda no sandbox.
- [ ] Sem `bwrap` no PATH, a ferramenta roda como hoje e o boot avisa.
- [ ] Atualize `docs/operations/DOCKER.md`: o `bwrap` dentro do container
      precisa de user namespaces; documente o que habilitar, ou rode com
      `none` no container até isso ser decidido.
- [ ] Commit: `feat(tools): processos externos rodam isolados no bubblewrap`.

### Fase B (depois da P-03)

#### F-05: A ferramenta `tarefa`

Crie a `tarefa` com iniciar, listar e cancelar, no processo da agente:
registro em `tasks.jsonl`, limite (D4) e ferramentas permitidas (D3).

**Aceite:**
- [ ] Iniciar uma `lenta(2000)` em segundo plano devolve na hora, e o turno
      responde sem esperar.
- [ ] Uma quarta tarefa simultânea é recusada com uma mensagem clara.
- [ ] Uma ferramenta fora da lista do D3 é recusada.
- [ ] I6 passa.
- [ ] Commit: `feat(self): tarefas em segundo plano`.

#### F-06: A entrega

Resultado gravado e depois entregue por `registry.inject` no chat de origem.
Orçamento esgotado guarda a entrega para a próxima mensagem da pessoa (D5).

**Aceite:**
- [ ] Teste e2e com o mock: iniciar, receber a resposta imediata, depois a
      mensagem `[Tarefa]`, e a resposta da agente com o resultado. O
      resultado fica no histórico como consulta.
- [ ] I7 passa: restart entre a conclusão e a entrega leva a exatamente uma
      entrega.
- [ ] Commit: `feat(self): o resultado da tarefa chega como mensagem`.

#### F-07: Esquecer, restart e o harness

- O `/esquecer` cancela as tarefas e descarta as entregas pendentes (I8).
- No boot, as tarefas interrompidas são avisadas (D6).
- Um cenário de harness: a pessoa pede um levantamento demorado. O critério é
  que a agente responda na hora, entregue o resultado depois, sem inventar o
  resultado antes de ele chegar, e use o resultado quando ele chega.

**Aceite:**
- [ ] I8 passa, inclusive com uma entrega já a caminho.
- [ ] Teste do aviso de interrupção no boot.
- [ ] O cenário de harness entra marcado como crítico, com calibração.
- [ ] Atualize `docs/operations/INTERACTION.md` (a agente pode trabalhar em
      segundo plano), o `PENDENCIAS` e `docs/ESTRESSE.md`.
- [ ] Commit: `feat(self): tarefas respeitam o esquecimento e o reinício`.

## 9. Critérios de aceite da PRD

- **Ferramenta travada:** o turno responde em no máximo o prazo da
  ferramenta mais o tempo do modelo, e não espera os 5 min da fila.
- **Turno abandonado ou tarefa cancelada:** nenhum processo fica vivo (I2).
- **Estresse com `--tool-mix`:** turnos/s sem regressão contra a F-00, e o
  processo com a maior fila não é um supervisor de ferramenta.
- **Tarefa em segundo plano:**
  - resposta imediata e entrega exatamente uma vez, com restart no meio;
  - cancelada pelo `/esquecer`;
  - aprovada no cenário de harness.
- **I1 a I8** passando, e a suíte inteira verde.

## 10. Riscos

| Risco | Mitigação |
|---|---|
| O modelo usa `tarefa` para tudo e a conversa vira um vaivém de mensagens | D3 limita as ferramentas; a descrição diz para usar só no que demora; o cenário de harness mede |
| O modelo anuncia o resultado antes de ele chegar | o cenário de harness tem critério de "não inventar" (como o `nao_inventar`); a resposta de `iniciar` diz "o resultado chega como mensagem" |
| Custo: cada entrega é um turno a mais do LLM | conta no orçamento da pessoa (D5), com limite de 3 tarefas (D4) |
| Matar um processo no meio de uma escrita em disco | as ferramentas que escrevem gravam em `.tmp` e depois fazem `rename` (como já fazem as do self); a F-00 levanta as que não fazem, e elas ganham isso antes da F-02 |
| Supervisor de ferramenta vira gargalo | as vagas são contadas na ETS, sem passar pelo supervisor; ele só inicia e cancela |
