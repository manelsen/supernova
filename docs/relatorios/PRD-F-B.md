# PRD-F, fase B: tarefas em segundo plano (F-05 a F-07)

Executada em 25 e 26/11/2026, na branch `prd-f/fase-b`.

## O que entrou

- **`self/tasks`**: o registro das tarefas. Um processo para a instância
  guarda os executores; cada tarefa roda num processo próprio, sem vínculo
  com o turno, sob o guarda da fase A (`tool_runner.start_in_slot`: prazo de
  30 min, vaga da ferramenta para o agente, cancelamento). Grava em
  `agents/<pessoa>/self/tasks.json` (`.tmp` e `rename`, trava por pessoa)
  antes de rodar, o desfecho antes de entregar, e `delivered` depois.
- **`tools/tarefa`**: `iniciar`, `listar`, `cancelar`. `argumentos` aceita
  objeto ou texto com JSON.
- **O turno** (`channel_common_router`) atende a `tarefa`, porque só ele sabe
  o chat de origem. A chamada em segundo plano passa pelo gateway como
  qualquer outra (capacidade, orçamento de ferramentas, auditoria). A própria
  `tarefa` respeita a capacidade do papel.
- **Entrega** (F-06): mensagem `[Tarefa] A tarefa 7 (<motivo>), que você
  iniciou às HH:MM, terminou: …` no chat de origem, pelo mesmo
  `registry.inject` da agenda. O resultado entra no histórico como a chamada
  de ferramenta que foi (`tool_call` e `tool`, formato da #59).
- **Sem orçamento** (D5): o resultado espera e vai na próxima mensagem da
  pessoa (`tasks.person_active`, chamado em todo turno que não é sintético).
- **Esquecer** (I8): o `/esquecer` mata os executores da pessoa e apaga o
  arquivo; uma entrega a caminho é descartada pela época.
- **Restart** (D6, I7): no boot, tarefa que rodava vira `interrupted` e a
  agente recebe o aviso; desfecho não entregue é entregue uma vez.
- **Capacidade**: `tarefa` entra na lista padrão dos membros. Uma
  instalação com `capabilities.member.allowed` próprio precisa acrescentá-la.
- **Métricas**: `tasks_total{outcome}` e `tasks_delivered_total{outcome}`.
- **Mock**: `[mock-tarefa <ferramenta> <ms>]`.

## Diferença do desenho

A PRD punha as tarefas no processo da agente (`self/desk`). Ficaram num
registro próprio da instância: o desk para depois de 30 min sem mudança,
o que mataria as tarefas longas, e o que a PRD queria dele (o `/esquecer`
serializado por agente) já vem do `desk.forgetting`, que chama
`forget.forget`, que chama `tasks.forget`. O comportamento é o descrito na
PRD.

## Testes

- `test/self/tasks_test.gleam` (15): resposta imediata e entrega depois no
  chat de origem (I6); oitava tarefa recusada (D4); instantâneas recusadas
  (D3); cancelar mata a chamada; prazo; `/esquecer` pelo registro e pelo
  `forget.forget` (I8); entrega a caminho descartada pela época (I8); sem
  orçamento espera a próxima mensagem (D5); restart entre desfecho e
  entrega entrega uma vez (I7); restart avisa a interrompida e não a refaz
  (D6); a mensagem leva de volta à tarefa; a ferramenta.
- Suíte inteira: 2961 testes, cobertura 82,53% (master: 82,41%).
- `test/e2e/tarefa_e2e_test.gleam`: pela pipeline real (grupo fechado,
  gateway, roteador, executor, mock). Conferido que falha sem o registro do
  resultado no histórico.

## Pendente: o cenário de harness da F-07

Não entrou. O harness não tem um passo que espere uma tarefa terminar, e a
entrega por `registry.inject` precisa que o canal `sim` do harness receba
mensagens injetadas e as ponha no transcript, o que hoje só a agenda faria
e nenhum cenário usa. Além disso, a calibração pede transcripts de exemplo
`pass` e `fail` que façam sentido para o juiz. Proposta: um passo
`"do": "wait_tasks"` no harness e o cenário "levantamento demorado",
numa PR à parte, com a sua revisão da rubrica.

**Atualização (26/11):** o passo `wait_tasks` entrou (decisão do
mantenedor), com o canal `sim` marcando o fim do turno também das mensagens
injetadas ([`HARNESS.md`](../HARNESS.md)). O cenário "levantamento demorado",
com rubrica e calibração, continua para o mantenedor.
