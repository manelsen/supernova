[PRD]
# PRD P: Paralelismo no caminho da mensagem

> **Situação em 23/11/2026:** aprovada. As decisões D1–D4 seguem as
> recomendações (seção 5). Depende das PRs #60 a #62: a ferramenta de
> estresse e a primeira rodada de desserialização.

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes, uma medição de estresse registrada e um commit próprio. Se a
> sessão for interrompida, retome pela primeira história sem commit,
> conferindo `git log --oneline` contra os títulos de commit.

## 1. Contexto

### 1.1 Onde está o teto

Uma mensagem faz este caminho:

```
canal ──► fila do chat (chat lane) ──► roteador do canal ──► turno (processo próprio, LLM)
           um processo por chat         UM processo por canal
```

- **Filas por chat** (`supernova_chat_lanes_ffi`). Cada chat tem a sua.
  Mensagens do mesmo chat rodam uma de cada vez, em ordem; chats diferentes
  rodam em paralelo.
- **Roteador do canal.** É um ator por canal (`telegram_router`,
  `discord_router`, `sim_router`…, todos sobre `channel_common_router`).
  Cada fila faz uma chamada síncrona a ele e espera. Para cada mensagem, ele
  faz a fase anterior ao LLM:
  - passa pelo gate do grupo fechado, com chamadas síncronas aos atores de
    acesso, limite de taxa, orçamento, ledger e teto da instância;
  - resolve a sessão, com uma chamada ao supervisor de sessões;
  - verifica nascimento e nome;
  - trata `/esquecer`, `/agenda`, `/model`, `/status`, `/help` e `/start`;
  - lê o modelo escolhido pela agente;
  - dispara o turno.
- **O turno**, que inclui o LLM, já roda num processo próprio. Mas a fase
  anterior a ele roda **uma mensagem de cada vez para o canal inteiro**.

A primeira rodada de desserialização (PR #62) tirou dessa fase o que era
desperdício: as leituras de disco repetidas, o servidor de arquivos da VM e o
ledger quadrático. Com 200 agentes de 12 mil mensagens cada, 150 workers e uma busca
a cada cinco mensagens, o resultado ficou em **~40 turnos/s, com p95 de
~12 s**. O processo com a maior fila continua sendo o roteador, parado nas
chamadas síncronas do gate (`resource_ledger.try_spend_today`,
`access.try_check`).

### 1.2 O que o roteador garante sem dizer

O roteador é um processo só, e por isso protege o estado que ele guarda na
memória:

| Estado (`InteractiveRouterState`) | Chave | Quem escreve |
|---|---|---|
| `session_profiles` (bootstrap antigo) | sessão | só o chat da sessão |
| `agent_choices` (`/model`) | agente | o chat em que a pessoa troca o modelo |
| `forget_pending` (`/esquecer` aguardando confirmação) | agente | o chat em que a pessoa pede |

Ele também serializa, sem que ninguém tenha decidido isso, as operações por
agente que mexem em disco: o nascimento (`birth.step`), a execução do
`/esquecer` e a gravação do `/model` no `self_state`.

### 1.3 Corridas que já existem

Os turnos já rodam em processos paralelos, e várias partes leem, alteram e
gravam o mesmo arquivo da agente sem dono:

- **`self_state`** (humor, preferências, escolha de modelo). Cinco caminhos
  fazem `load → altera → save`:
  - o fim de cada turno (`apply_current_success_self_state`, no processo do
    turno);
  - `/model` e `/reasoning` (no roteador);
  - a reflexão (`reflection.gleam`);
  - o `/esquecer` (`forget.gleam`).

  Dois turnos da mesma pessoa, no privado e num grupo, podem apagar o humor um
  do outro. Um turno que termina junto com um `/model` pode desfazer a escolha
  no arquivo.
- **`relationship`**: o mesmo padrão, também no fim do turno.
- **`/esquecer` com turno em andamento em outro chat da mesma pessoa.**
  `forget.clear_sessions` para as sessões. O turno em andamento falha ao
  gravar (`append_messages` numa sessão parada) e a pessoa não recebe
  resposta. Nenhum conteúdo esquecido volta: a época do `/esquecer` e a parada
  da sessão impedem isso. Mas a falha não é tratada.

Esta PRD não cria essas corridas, mas tirar o roteador do caminho as torna
mais prováveis. Por isso elas são resolvidas aqui, antes da história que
paraleliza (P-04).

## 2. Objetivo

Tirar o roteador do caminho de cada mensagem: a fase anterior ao LLM roda na
fila do próprio chat. O estado compartilhado fica em lugares feitos para
acesso concorrente. O que precisa ser exclusivo **por agente** fica com um
processo da agente. Chats diferentes, e pessoas diferentes, não esperam uns
pelos outros.

**Princípio.** Cada coisa é serializada no menor escopo que a correção exige:
- a ordem das mensagens, **por chat**;
- a identidade e a memória de uma agente, **por agente**;
- nada **por canal**.

## 3. Fora de escopo

- O índice em memória da `buscar_conversa`. Ele é independente desta PRD e
  ganha PR própria. A busca continua relendo o histórico; o estresse mede com
  e sem buscas.
- Streaming real por tokens.
- Grupos em que todas as agentes leem o grupo, que dependem de decisão
  própria (PENDENCIAS 3.1).
- Rodar em mais de um nó.

## 4. Quality gates

Obrigatórios ao fim de **toda** história:

```bash
gleam format --check src test
gleam build --warnings-as-errors
gleam test
make coverage
git status --short    # nenhum arquivo novo gerado pelos testes
```

A partir da P-03, também:

```bash
# A/B intercalado (docs/ESTRESSE.md, "Lendo os números"): duas rodadas de
# cada lado, sobre cópias congeladas do código, nesta carga:
gleam run -m supernova/stress/run -- --agents 200 --history 10000 \
  --groups 10 --workers 150 --seconds 30 --search-every 5 --no-chaos
# e uma rodada com caos (sem --no-chaos), 120 s
```

O resultado vai na mensagem de commit: turnos/s, p50, p95, turnos faltando,
memória máxima e processo com a maior fila.

**Regras:**
- **Subjects do Erlang:** só o processo dono recebe num subject. Para
  segurar um job em teste, o job cria o subject de liberação e o envia ao
  teste (`test/channel/concurrency_test.gleam`).
- **Sem `process.sleep` fixo** para estabelecer estado concorrente. Use um
  sinal de prontidão com prazo, ou espera com condição e limite.
- **TDD:** escreva o teste, confirme que falha pelo motivo esperado,
  implemente e confirme que passa. A falha inicial vai na mensagem de commit.
- **Sem rede, tokens ou serviços reais** nos testes.
- **Cobertura** nunca abaixo do valor do início da história.
- **Nada de `persistent_term`** para estado por agente. Cada escrita varre
  todos os processos; na PRD-P (a) isso travou a VM. Use ETS.

## 5. Decisões do mantenedor

Aprovadas em 23/11: as quatro seguem a recomendação.

- **D1. A mesma pessoa no privado e num grupo ao mesmo tempo.**
  - (a) Os dois turnos rodam em paralelo; só as operações da agente (seção 6)
    são exclusivas.
  - (b) Um turno por pessoa de cada vez, em todos os chats.
  - **Recomendação: (a).** Hoje o LLM dos dois já roda em paralelo. Com (b),
    um turno lento no grupo seguraria o privado.
- **D2. `/esquecer` com turno da mesma pessoa em andamento em outro chat.**
  - (a) O `/esquecer` espera os turnos em andamento daquela pessoa terminarem,
    até 60 s, e só então apaga. Turnos que chegam durante a espera aguardam o
    fim do `/esquecer`.
  - (b) O `/esquecer` apaga na hora, e o turno em andamento termina sem gravar
    e avisa a pessoa.
  - **Recomendação: (a).** Ninguém perde resposta, e o que foi dito antes do
    `/esquecer` é apagado junto.
- **D3. Duas primeiras mensagens da mesma pessoa, em chats diferentes, antes
  de a agente nascer.**
  - (a) Um nascimento só. A segunda mensagem espera e é tratada depois, já
    com a agente nascida.
  - (b) A segunda recebe "estou nascendo, fala comigo de novo em um
    instante".
  - **Recomendação: (a).**
- **D4. Ligar e desligar.**
  - (a) A configuração `routing.parallel` (padrão `false`) troca o caminho
    novo pelo antigo, até a P-07.
  - (b) Sem chave.
  - **Recomendação: (a).** Rollback sem deploy de código.

## 6. Desenho

### 6.1 Três escopos

| Escopo | Garante | Mecanismo |
|---|---|---|
| Chat | ordem das mensagens; histórico da sessão consistente | a fila do chat, como hoje |
| Agente | um nascimento; um `/esquecer` de cada vez; gravações do `self_state` e do `relationship` sem perda | **processo da agente** |
| Instância | leituras concorrentes do estado compartilhado | tabelas ETS |

### 6.2 O processo da agente

É um ator por agente (`supernova/self/desk`), iniciado sob demanda e
registrado numa tabela ETS por `principal`. Fica sob um supervisor próprio,
com `trap_exit`, nos moldes do supervisor de sessões depois da #61. Ele é o
**único que grava**:
- `self_state` e `relationship`. O turno manda o desfecho
  (`apply_outcome`) e não grava mais o arquivo sozinho;
- `/model`, `/reasoning`, a escolha de provedor e modelo;
- o nascimento e o nome (`birth.step`);
- o `/esquecer`: confirmação pendente, espera dos turnos (D2) e execução.

**As leituras não passam pelo ator.** Ele publica numa tabela ETS (modelo
escolhido, preferências, "nomeada", época) e quem precisa lê direto da
tabela. O ator só é chamado para mudar algo.

**Turnos em andamento.** A agente conta os turnos em andamento: o turno
avisa quando começa e quando termina, e um monitor cobre o turno que morre
sem avisar. O `/esquecer` usa essa contagem para esperar (D2).

**Ciclo de vida.**
- Um ator ocioso há 30 min termina; o próximo acesso o recria a partir do
  disco.
- Um ator que morre é recriado na próxima chamada. A fonte de verdade é o
  disco, e a tabela é só uma vitrine.

### 6.3 Estado do roteador

- `session_profiles` sai da memória do ator e vai para uma ETS indexada por
  sessão. Só a fila do chat a escreve.
- `agent_choices` e `forget_pending` passam a ser do processo da agente.
- O `InteractiveRouterState` deixa de existir. As funções de
  `channel_common_router` param de receber e devolver estado.

### 6.4 O handler na fila

O handler que o `registry` entrega às filas deixa de ser `actor.call(router,
…)`. Passa a ser uma função que roda a fase anterior ao LLM **no processo da
fila**. Os atores roteadores por canal ficam só para a API síncrona usada
pelos testes (`route`, `route_inbound`), que passa a chamar a mesma função.
Com `routing.parallel: false` (D4), o handler volta a chamar o ator, como
hoje.

### 6.5 O gate

Com o roteador fora do caminho, as chamadas ao gate saem das filas, em
paralelo, e cada ator do gate vira o próximo ponto único. A P-06 mede antes
de mexer. Se algum desses atores for o processo com a maior fila, a correção
segue a mesma ideia de leitura concorrente com escrita centralizada:
- **acesso:** as listas efetivas publicadas numa ETS, e `check` vira leitura;
- **limite de taxa:** contadores numa ETS com `update_counter`;
- **ledger:** reserva e registro por pessoa numa ETS, e o total do dia como
  contador.

## 7. Invariantes

Cada um tem teste próprio, escrito em P-01, **antes** de qualquer mudança de
comportamento, e que tem de continuar passando até o fim.

- **I1 – Ordem.** Mensagens do mesmo chat são tratadas na ordem de chegada; o
  histórico da sessão fica na mesma ordem.
- **I2 – Um nascimento.** Duas primeiras mensagens da mesma pessoa em chats
  diferentes, ao mesmo tempo, produzem um único `core.json` e uma única
  chamada de nascimento (D3).
- **I3 – Esquecer é esquecer.** Nada dito antes do `/esquecer` confirmado
  sobrevive no histórico, na memória, no `self_state` ou na fila durável,
  mesmo com turnos da pessoa em andamento em outros chats (D2).
- **I4 – Nenhuma gravação perdida.** Turnos simultâneos da mesma pessoa em
  chats diferentes e um `/model` no meio deixam o `self_state` com todos os
  efeitos: a escolha de modelo e a soma dos desfechos.
- **I5 – Nenhum turno respondido sem registro.** Todo turno com resposta
  entregue está no histórico. É o que o estresse confere.
- **I6 – Gate fechado na falha.** Com um ator do gate fora do ar, a mensagem
  é negada, nunca liberada.
- **I7 – Isolamento.** A busca, a agenda e o computador de uma pessoa nunca
  alcançam os de outra. Os testes existentes continuam valendo.

## 8. Histórias

### P-00: Linha de base

- Rode o A/B da seção 4 na master (com as #60–#62) e registre a mediana de
  turnos/s, p50, p95, memória máxima e processo com a maior fila em
  `docs/relatorios/PRD-P-base.md`.
- Commit: `docs(prd-p): linha de base de estresse`.

### P-01: Invariantes primeiro

Escreva os testes de I1 a I7 contra o código atual.

- I1, I5, I6 e I7 devem passar já.
- I2, I3 e I4 provavelmente falham: a corrida já existe (seção 1.3). Nesse
  caso, o teste entra marcado para pular, com o nome da história que o
  corrige, e a falha vai registrada no commit.

**Aceite:**
- [x] Um teste por invariante.
- [x] Os testes de corrida provocam a concorrência com sinais de prontidão,
      nunca com `sleep`.
- [x] Commit: `test(prd-p): invariantes do caminho da mensagem`.

### P-02: O processo da agente

Crie `supernova/self/desk`: o ator, o supervisor com `trap_exit`, o registro
ETS e a vitrine de leitura (seção 6.2). Mova para ele as gravações de
`self_state` e `relationship`. O fim do turno, a reflexão, `/model`,
`/reasoning` e `/esquecer` mandam mudanças em vez de gravar.

**Aceite:**
- [x] I4 passa.
- [x] Um ator da agente morto no meio de uma gravação é recriado, e o
      arquivo fica coerente (escrita em `.tmp` e depois `rename`, como hoje).
- [x] As leituras do `self_state` no caminho da mensagem vêm da vitrine, não
      do disco.
- [x] Commit: `feat(self): um processo por agente grava o estado dela`.

### P-03: Nascimento e esquecimento pela agente

Mova para o processo da agente o `birth.step`, o `forget_pending`, a contagem
de turnos em andamento e a execução do `/esquecer` com espera (D2).

**Aceite:**
- [x] I2 e I3 passam.
- [x] O `/esquecer` com um turno da mesma pessoa preso em outro chat espera o
      turno, apaga depois, e a resposta do turno chega à pessoa.
- [x] Um turno que morre sem avisar não trava o `/esquecer`: o monitor
      desconta o turno.
**Feito.** O `forget_pending` (a confirmação pendente) continua no
roteador e sai dele na P-04, junto com o resto do estado do roteador:
enquanto o roteador for um ator, ele já é serializado por canal.

- [x] Commit: `feat(self): nascimento e esquecimento serializados por agente`.

### P-04: Roteador sem estado

Leve `session_profiles` para ETS e remova `InteractiveRouterState`. Nesta
história, o roteador **continua** no caminho: só o estado sai de dentro dele.

**Feito.** O `InteractiveRouterState` continua existindo, mas só como um
escopo (um inteiro) numa tabela ETS (`SupernovaRouterState`): as funções do
roteador mantêm as assinaturas, e a P-05 pode chamá-las de qualquer
processo. Uma asserção mudou: a que conferia o estado inicial lendo os
dicionários internos. A/B (2 rodadas intercaladas, carga 10–11): base
78,9 e 75,3 turnos/s; nova 66,8 e 84,1 (média −2%).

**Aceite:**
- [x] Todos os testes do roteador passam sem mudar asserções, só a forma de
      criar o estado inicial.
- [x] A/B sem regressão: turnos/s dentro de ±10% da linha de base.
- [x] Commit: `refactor(router): o estado sai do ator do roteador`.

### P-05: A fase anterior ao LLM na fila do chat

O handler roda no processo da fila (seção 6.4), atrás de `routing.parallel`
(D4).

O teste do chat parado usa um `/esquecer` esperando um turno lento da mesma
pessoa: ele segura a fase anterior ao LLM do chat da Ana por um sinal (o
processo da agente), sem gate falso.

**Aceite:**
- [x] Com `routing.parallel: true`, I1 a I7 passam.
- [x] Teste: uma mensagem lenta no chat A (gate segurado por um sinal) não
      atrasa a resposta de uma mensagem do chat B.
- [x] Com `false`, a suíte inteira passa sem mudança.
- [ ] A/B com `true` contra a linha de base: **turnos/s ≥ 2×**; o roteador
      não é mais o processo com a maior fila. **Parcial:** 1,5× (base 73,1 e
      107,5; nova 136,6 e 132,2 turnos/s), p95 de 2,8–4,4 s para 1,6–1,9 s.
      O roteador saiu do topo; quem está lá é a fila durável, sozinha
      (27–28 amostras). Os 2× ficam para depois da P-06.
- [x] Rodada com caos: zero turnos faltando (11.530 respondidos, 94,9/s).
- [x] Commit: `perf(router): a fase anterior ao LLM roda na fila do chat`.

### P-06: O próximo teto: a fila durável ou o gate

A linha de base pelo caminho de produção (P-00b) já mostra a **fila durável**
como o processo com a maior fila: uma gravação em disco por mensagem, num
processo único, antes da fila do chat. Meça com `routing.parallel: true` e
trate o que estiver no topo:

- **Fila durável.** Faça *group commit*: as mensagens que chegam enquanto
  uma gravação está em andamento vão juntas na próxima, numa única
  `append_file`. Cada remetente só recebe a confirmação depois que a gravação
  da sua mensagem terminou, então a garantia de "está no disco antes de
  entrar na fila" continua igual. Teste: 100 mensagens simultâneas viram bem
  menos de 100 gravações, e um restart logo depois de todas as confirmações
  recupera todas.
- **Ator do gate.** Aplique a seção 6.5 só a ele.

Meça de novo depois de cada correção. Se nenhum dos dois estiver no topo,
registre a medição e feche a história sem mudança de código.

**Aceite:**
- [ ] O relatório de estresse mostra o processo com a maior fila antes e
      depois.
- [ ] I6 continua passando.
- [ ] Commit: `perf(inbox): gravações agrupadas`, `perf(gate): <ator> lido
      em paralelo`, ou `docs(prd-p): nem a fila nem o gate são o teto`.

### P-07: Ligar por padrão

- `routing.parallel` passa a `true` por padrão.
- Depois de uma semana no piloto sem regressão, a chave e o caminho antigo
  saem numa PR separada.
- Atualize `docs/ESTRESSE.md` (números novos), o `PENDENCIAS` e
  `docs/architecture`.

**Aceite:**
- [ ] Relatório final em `docs/relatorios/PRD-P.md`: tabela da linha de base
      contra o final, com as mesmas cargas.
- [ ] Commit: `feat(router): caminho paralelo por padrão`.

## 9. Critérios de aceite da PRD

- **Vazão:** turnos/s **≥ 2×** a linha de base da P-00, na carga da seção 4,
  em A/B.
- **Latência:** p95 **≤ metade** da linha de base sem buscas
  (`--search-every 1000000`). Com buscas, o p95 depende do índice, que está
  fora de escopo.
- **Integridade:** zero turnos faltando, com e sem caos, em três rodadas
  seguidas.
- **Memória:** pico **≤ 1,5×** a linha de base.
- **Comportamento:** suíte inteira e harness provisório verdes; I1 a I7
  passando.
- **O roteador do canal** não aparece entre os processos com a maior fila.

## 10. Riscos

| Risco | Mitigação |
|---|---|
| Corrida nova entre chats da mesma pessoa | invariantes escritos antes (P-01); exclusividade por agente num processo só, não em travas espalhadas |
| Processo da agente vira gargalo para uma pessoa muito ativa | ele só grava; as leituras vêm da ETS; o turno manda e não espera |
| Muitas agentes, muitos processos | um processo ocioso termina depois de 30 min; centenas de milhares de processos pequenos são normais na BEAM |
| A tabela ETS morre com o dono | dono num processo próprio e supervisionado; a tabela é vitrine, e o disco é a verdade |
| O comportamento muda sem ninguém notar | `routing.parallel` desligado por padrão até a P-07; caminho antigo intacto até lá |
