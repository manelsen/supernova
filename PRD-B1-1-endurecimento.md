[PRD]
# PRD B1.1: Endurecimento do grupo fechado antes da B2

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar. Execute as fases e as histórias **na ordem**. Cada história termina com os quality gates verdes e um commit próprio.
>
> **Dimensionamento:** 18 histórias em duas fases. Se a sessão for interrompida, retome pela primeira história sem commit, conferindo `git log --oneline` contra os títulos de commit de cada história.

## 1. Contexto

A PRD B1 (grupo fechado e kernel ligado) está no PR #12, branch `feat/grupo-fechado`. Uma revisão humana corrigiu problemas de concorrência e autorização (commits `d82cb54` a `1a2259c`). Em seguida, a revisão do CodeRabbit no commit `1a2259c` trouxe 30 comentários. Eles foram verificados contra o código, e esta PRD formaliza os que procedem.

A PRD B2 (o self de cada agente) virá depois e dependerá diretamente de orçamento, ledger e concorrência. Cada self terá orçamento próprio e um loop de introspecção rodando sozinho. Por isso, **nenhuma dívida desta lista pode passar para a B2**.

- **Fase A:** segurança, revogação de acesso e ordem das conversas. Entra no próprio PR #12.
- **Fase B:** precisão de custo e bordas de entrega. Vai num PR separado, "B1.1".

## 2. Fora de escopo

- Qualquer coisa da B2 (self, constituição, introspecção) ou da B3 (convivência entre agentes).
- Streaming real por tokens. O "stream" atual é uma chamada única entregue de forma assíncrona; isso continua assim.
- Traduzir "Thinking..." e "Streaming timed out".
- Tags, publicação de imagens e merge de PRs.

## 3. Quality gates

Obrigatórios ao fim de **toda** história:

```bash
gleam format --check src test
gleam build --warnings-as-errors
gleam test
make coverage
git status --short    # nenhum arquivo novo gerado pelos testes
```

Regras:

- **Segurança dos testes (obrigatória):** nenhum teste pode **executar** um comando que deveria ser bloqueado. Teste bloqueios com funções de validação (`safe_shell.validate/1`). Em 17/11, um teste que executou `find . -delete` apagou o repositório inteiro.
- **Subjects do Erlang:** `process.receive` só funciona no processo **dono** do subject. Para bloquear um job ou um handler em teste, o próprio job cria o subject de liberação e o envia ao teste (veja `test/channel/concurrency_test.gleam`).
- **Sincronização em testes:** use um sinal de prontidão com prazo, nunca `process.sleep` fixo, para estabelecer estado concorrente.
- **TDD:** escreva o teste, rode e **confirme que falha** pelo motivo esperado, implemente, rode e confirme que passa. Registre a falha inicial na mensagem de commit.
- Testes não usam rede real, tokens reais, Postgres real nem Chromium real.
- A cobertura não pode cair abaixo do valor do início de cada história.

## 4. Preparação

1. `cd ~/git/supernova && git status --short`. Precisa estar vazio; se não estiver, **pare** e registre.
2. `git fetch origin && git switch feat/grupo-fechado && git pull --ff-only`
3. Confirme que o último commit é `1a2259c` ou posterior: `git log --oneline -1`.
4. Registre a linha de base: testes, cobertura e `gleam --version`.

---

# FASE A — no PR #12 (branch `feat/grupo-fechado`)

### A-01: Revogação pelo YAML volta a funcionar

**Problema:** `TakeDeniedNotice` e `TakeChatDeniedNotice` (`src/supernova/core/access/actor.gleam`) chamam `persist_best_effort`, que grava em `access.json` as **listas inteiras**. No boot, `pure.apply_persisted` substitui as listas do YAML pelas persistidas. Basta um estranho receber uma negação para o YAML parar de valer: remover alguém do YAML e reiniciar não revoga o acesso.

**Desenho exigido:** o YAML é a base. `access.json` guarda só as **diferenças** feitas por comando:

```json
{ "added":   { "admins": [...], "members": [...], "allowed_chats": [...] },
  "removed": { "admins": [...], "members": [...], "allowed_chats": [...] },
  "denied_notices": {...}, "chat_denied_notices": {...} }
```

Lista efetiva = (YAML ∪ added) − removed, calculada por uma função pura. `/acesso adicionar X` inclui X em `added` e o retira de `removed`; `/acesso remover X` faz o contrário.

**Critérios de aceite:**
- [ ] Teste que falha hoje: com YAML `members: [A]`, um estranho B recebe uma negação; reinicie o ator com YAML `members: []`; A **deve** ser negado.
- [ ] Teste: com YAML `members: [A, C]`, `/acesso remover A`; reinicie com o mesmo YAML; A continua negado e C continua permitido.
- [ ] Teste: `/acesso adicionar D` sobrevive ao reinício mesmo sem D no YAML.
- [ ] Migração: um `access.json` no formato antigo (listas inteiras) é lido como `added = listas − YAML` e `removed = []`, e regravado no formato novo. Teste com um arquivo antigo de exemplo.
- [ ] Gravar avisos de negação nunca grava listas.
- [ ] Commit: `fix(access): persist command deltas so YAML edits are honored`.

### A-02: Workspace sem política impede o boot

**Problema:** em `src/supernova.gleam` (cerca da linha 525), se `workspace_policy_actor.start` falhar, o boot segue com `None`, e o gateway deixa de checar caminhos (`check_workspace_policy` e a checagem de argumentos devolvem `Ok` quando a política é `None`).

**Critérios de aceite:**
- [ ] Em produção, a falha ao iniciar a política de workspace faz `start_closed_group_supervisor` devolver `Error` com mensagem clara, e a aplicação não sobe.
- [ ] No gateway, se não houver política **e** houver manifestos de capability configurados (modo grupo fechado), ferramentas com argumento de caminho e as operações `ReadFile` e `WriteFile` são **negadas** com `"workspace policy unavailable"`. O comportamento para `start()` sem manifestos (testes antigos) não muda.
- [ ] Testes: o boot falha com um `data_dir` impossível de criar (use um caminho sob um **arquivo** temporário criado pelo teste); o gateway com manifestos e sem política nega `file_system` com caminho.
- [ ] Commit: `fix(kernel): fail closed when the workspace policy cannot start`.

### A-03: Comandos de relatório exigem chat autorizado

**Problema:** em `src/supernova/core/closed_group/runtime.gleam` (cerca da linha 80), um admin executa **qualquer** comando antes da checagem do chat. `/auditoria` e `/uso todos` respondem num grupo não autorizado, e todos os participantes leem.

**Critérios de aceite:**
- [ ] Antes da checagem do chat, só passam `/eu` e os comandos de gestão de chat: `/acesso chat adicionar`, `/acesso chat remover` e `/acesso chat listar`. Todos os outros comandos de admin (`/auditoria`, `/uso`, `/uso todos`, `/teto`, `/acesso adicionar|remover|listar`) passam pela checagem do chat como qualquer mensagem.
- [ ] Em conversa privada nada muda.
- [ ] Testes: num grupo não autorizado, um admin com `/auditoria` não recebe o relatório (resposta `Ignored`); com `/acesso chat adicionar` funciona; depois de autorizar o grupo, `/auditoria` funciona.
- [ ] Commit: `fix(access): only chat-management commands bypass the chat check`.

### A-04: Git realmente somente leitura

**Problema:** `validate_git_args` (`src/supernova/tools/safe_shell.gleam`) só checa o subcomando e três opções. Passam `git branch -D main`, `git branch novo`, `git diff --output=/tmp/x` e `git diff --no-index /etc/passwd /dev/null`.

**Desenho exigido:** uma **lista de opções permitidas por subcomando**. Tudo que começa com `-` e não está na lista é rejeitado.

| Subcomando | Opções permitidas | Argumentos posicionais |
|---|---|---|
| `status` | `--short`, `-s`, `--branch`, `-b`, `--porcelain` | nenhum |
| `log` | `--oneline`, `--stat`, `--graph`, `--decorate`, `-<N>` (só dígitos, ex.: `-10`), `--max-count=<N>`, `-n` seguido de um número | até 1 (revisão) |
| `branch` | `--show-current`, `--list`, `-a`, `-r`, `-v`, `-vv` | **nenhum** |
| `diff` | `--stat`, `--name-only`, `--name-status`, `--cached`, `--staged` | até 2 |
| `show` | `--stat`, `--name-only`, `--oneline` | até 1 |

Argumentos posicionais passam por `workspace_guard.validate_path(".", arg)`: não podem ser absolutos nem conter `..`.

**Critérios de aceite:**
- [ ] Rejeitados em `validate/1`: `git branch -D main`, `git branch novo`, `git branch -m a b`, `git diff --output=/tmp/x`, `git show --output=x`, `git diff --no-index /etc/passwd /dev/null`, `git log --exec=x`, `git diff --ext-diff`, `git diff --textconv`, `git log -n abc`.
- [ ] Aceitos: `git status --short`, `git log --oneline -10`, `git branch --show-current`, `git diff --stat`, `git show HEAD --stat`.
- [ ] Os testes de rejeição usam **somente** `safe_shell.validate/1`.
- [ ] As três funções de `git_inspect` continuam funcionando no teste com repositório temporário.
- [ ] Commit: `fix(safe_shell): allow-list git options per subcommand`.

### A-05: Lentidão do acesso não faz o bot sair de grupo autorizado

**Problema:** `closed_group_global.chat_authorized` usa `access_actor.list_chats`, que devolve `[]` em caso de timeout (`call_or`). Por isso, uma lentidão momentânea leva o bot a sair de um grupo que está na lista.

**Critérios de aceite:**
- [ ] Crie `access_actor.try_list_chats(access) -> Result(List(String), Nil)` e `closed_group_global.chat_authorized_result(chat_key) -> Result(Bool, Nil)`.
- [ ] Em `maybe_leave_unauthorized_group` (`src/supernova/channel/registry.gleam`): com `Error`, **não sai**; registra um log `warn`, um audit `chat_check_failed` e agenda **uma** nova checagem em 30 s num processo separado. Se a nova checagem também falhar, não sai e registra de novo.
- [ ] O bot só sai quando a checagem responde e o chat não está autorizado.
- [ ] Testes: um ator de acesso que não responde não provoca saída; um que responde "não autorizado" provoca. Use o hook `leave_group` existente.
- [ ] Commit: `fix(registry): never leave a group when the access lookup fails`.

### A-06: Compose e dados persistentes

**Critérios de aceite:**
- [ ] Em `docker-compose.yml`, o serviço `supernova` repassa `SUPERNOVA_TELEGRAM_TOKEN`, `SUPERNOVA_ACCESS_ADMINS` e `SUPERNOVA_ACCESS_MEMBERS` (no padrão `${VAR:-}` já usado), define `SUPERNOVA_DATA_DIR: /data` e monta um volume nomeado `supernova_data:/data`, declarado em `volumes:`.
- [ ] Confirme no código que `SUPERNOVA_DATA_DIR` é lido (`src/supernova/config.gleam`, cerca da linha 1388) e que `access.json`, o ledger e o audit log ficam sob `data_dir`. Se algum ficar fora, ajuste para ficar dentro e registre.
- [ ] Em `DEPLOY.md`, seção "Grupo fechado":
  - como definir o primeiro admin (variável no `.env` ao lado do compose ou `access.admins` no YAML montado);
  - que `access.json` guarda as alterações feitas por comando e que o YAML continua valendo (A-01);
  - como copiar um `data` existente para o volume antes de trocar o contêiner (`docker cp` para um contêiner temporário montando o volume).
- [ ] O smoke test de `DEPLOY.md` continua válido. Rode-o se houver Docker disponível; se não houver, registre.
- [ ] Commit: `fix(deploy): forward access and Telegram settings; persist data_dir`.

### A-07: Fila por chat com limite

**Problema:** `supernova_chat_lanes_ffi` aceita jobs sem limite. Num flood, eles se acumulam antes de chegar ao rate limit, que só roda dentro do job.

**Critérios de aceite:**
- [ ] Limites no gerente: **50 jobs pendentes por chat** e **2000 chats ativos**. Acima de qualquer um deles, `submit` descarta o job, devolve `False` e registra um log `warn` com a chave do chat, sem bloquear o chamador. Dentro do limite, devolve `True`.
- [ ] `chat_lanes.submit` passa a devolver `Bool`. `dispatch_inbound` ignora o retorno (o log já foi feito).
- [ ] Exponha os limites para teste (por exemplo, `submit_with_limits(key, job, max_pending, max_lanes)` usado pelo `submit` normal).
- [ ] Testes: com `max_pending = 2` e um job bloqueado, o terceiro e o quarto são recusados; depois da liberação, novos jobs são aceitos; a ordem dos aceitos se mantém.
- [ ] Commit: `fix(lanes): bound pending turns per chat and active lanes`.

### A-08: A fila só libera quando o turno termina

**Problema:** o job da fila termina quando a entrega do stream acaba, inclusive no timeout de 60 s (`stream_timeout_ms`). Mas o executor, iniciado em processo separado pelo router, pode continuar rodando. Então o turno seguinte do mesmo chat lê o histórico da sessão antes de o anterior gravar.

**Desenho exigido:**
- O worker do turno (`run_streamed_message_reply`, em `src/supernova/adapters/channel_common_router.gleam`) **sempre** termina emitindo exatamente um evento terminal (`StreamComplete` ou `StreamFailure`), inclusive se o executor falhar. Para isso, envolva o executor de forma que exceções virem `StreamFailure`.
- No registry, quando o timeout de entrega chega, o aviso de timeout continua sendo enviado como hoje, mas o job **continua esperando** o evento terminal por até `turn_hard_timeout_ms = 300_000`. Se ele chegar nesse intervalo, o conteúdo final é entregue como **mensagem nova**, já dividida no limite do canal. Só então o job termina e a fila libera o próximo turno.
- Se nem o prazo longo for cumprido, o job termina e registra um log `error` com a chave do chat.

**Critérios de aceite:**
- [ ] Teste com o gravador de testes do registry: um turno cujo evento terminal chega depois do timeout de entrega gera o aviso de timeout seguido de uma mensagem nova com o conteúdo; um segundo turno do mesmo chat só começa depois disso. Use um handler de teste que controla o envio dos eventos e reduza os timeouts por um hook de teste (por exemplo, `StartHooks.stream_timeout_ms` e `turn_hard_timeout_ms`), sem esperar 60 s de verdade.
- [ ] Teste: um executor que lança exceção produz `StreamFailure`, e a fila é liberada.
- [ ] Commit: `fix(lanes): release a chat lane only when its turn has finished`.

### A-09: Testes mais rigorosos

**Critérios de aceite:**
- [ ] `test/e2e/e2e_support.gleam`: `await_content` usa prazo **total** monotônico (5 s), e não só tempo ocioso.
- [ ] `test/e2e/telegram_e2e_test.gleam` (`leaves_unauthorized_group_and_audits_test`): consulte o audit log repetidamente até a entrada aparecer, com prazo de 2 s, em vez de ler uma única vez.
- [ ] `test/adapters/closed_group_router_test.gleam`:
  - assincronia: prove que o handler devolve `StreamReply` **antes** de o executor terminar. Crie no mock do LLM (`src/supernova/llm/client.gleam`, `special_mock_response`) um marcador `[mock-delay-ms=N]` que atrasa a resposta em N ms. Exija que o handler volte em menos de 300 ms com `[mock-delay-ms=1500]` e que o conteúdo final chegue depois;
  - recusa por orçamento zero: exija `Ok(port.ImmediateReply(_))` com o texto de limite;
  - primeiro clique de não membro: exija `Ok(port.ImmediateReply(reply))` com `reply.content == "Esta instância é privada."`.
- [ ] `test/channel/concurrency_test.gleam` (`slow_tool_neither_refused_nor_blocking_test`): o executor lento sinaliza prontidão e espera um subject de liberação criado por ele mesmo. A ferramenta rápida é chamada **depois** da prontidão e precisa terminar com a lenta ainda bloqueada. A lenta só é liberada depois de 2,5 s, para continuar cobrindo o timeout do gateway.
- [ ] Commit: `test: tighten async, refusal and concurrency assertions`.

### A-10: Fechamento da Fase A

**Critérios de aceite:**
- [ ] Acrescente a `docs/B1_REPORT.md` uma seção "Correções da revisão CodeRabbit (Fase A)", com uma tabela problema → correção → teste.
- [ ] `git push origin feat/grupo-fechado`.
- [ ] Espere o CI do PR #12 (`gh pr checks 12 -R manelsen/supernova --watch`). Se falhar, corrija e repita.
- [ ] Commit: `docs: record phase A hardening in the B1 report`.

---

# FASE B — PR "B1.1" (branch `fix/b1-1-endurecimento`)

Preparação da Fase B:

1. `git switch -c fix/b1-1-endurecimento` a partir de `feat/grupo-fechado` atualizado.
2. Se o PR #12 já tiver sido mesclado (`gh pr view 12 -R manelsen/supernova --json state`), faça antes `git fetch origin && git rebase origin/master`.

### B-01: A estimativa de custo inclui ferramentas

**Problema:** `record_llm_usage` e `prompt_token_estimate` (`src/supernova/core/executor.gleam`, cerca da linha 553) contam só o texto das mensagens e da resposta. As definições de ferramentas enviadas em cada chamada e os argumentos das chamadas de ferramenta ficam de fora, e um turno que só chama ferramenta conta 1 token de saída.

**Critérios de aceite:**
- [ ] Prompt estimado = mensagens + definições de ferramentas da chamada (nome, descrição e JSON dos parâmetros) + argumentos das chamadas de ferramenta já presentes no histórico.
- [ ] Saída estimada = conteúdo da resposta + argumentos das chamadas de ferramenta da resposta.
- [ ] Mantenha a regra caracteres/4, ou o `usage` do provider quando existir.
- [ ] Testes: um turno com ferramentas estima mais tokens que o mesmo turno sem ferramentas; uma resposta só com chamada de ferramenta conta os argumentos.
- [ ] Commit: `fix(budget): count tool definitions and tool calls in usage estimates`.

### B-02: Totais por dia no ledger

**Problema:** `GetLLMCostWhere` percorre todo o histórico dentro do ator do ledger a cada checagem do teto. O `RotateOldFiles` apaga arquivos antigos, mas não remove esses eventos da memória.

**Critérios de aceite:**
- [ ] O ledger mantém um `Dict(String, Float)` de custo por dia, com a chave calculada por uma função `day_key: fn(Int) -> String` recebida na inicialização. Em produção, é `pricing.day_key(_, timezone)`.
- [ ] Cada registro de uso atualiza o total do dia em O(1). Na carga dos arquivos, os totais são reconstruídos.
- [ ] Nova consulta `try_spend_today(ledger, now) -> Result(#(String, Float), Nil)`, que devolve **o dia e o total juntos**. `daily_spend` passa a usá-la.
- [ ] `instance_budget.check` recebe o dia junto com o total. Se o dia não for o dia corrente do próprio relógio, pede o total de novo, uma vez.
- [ ] `RotateOldFiles` também remove da memória os eventos e os totais fora da janela de retenção.
- [ ] Remova `GetLLMCostWhere` e `try_llm_cost_where` e adapte o teste existente.
- [ ] Testes: o total do dia é atualizado sem varrer o histórico; a virada do dia no fuso; a rotação poda a memória; o caso "total de ontem lido logo antes da meia-noite" não bloqueia o dia novo.
- [ ] Commit: `perf(ledger): maintain per-day spend totals`.

### B-03: Reserva de custo na admissão (teto sem estouro por concorrência)

**Problema:** com teto de US$ 10, o turno A lê US$ 9 e pausa; o turno B termina e registra US$ 1; A volta e é admitido. A admissão e o gasto registrado não têm o mesmo dono.

**Desenho exigido:** a admissão e o registro passam a ser feitos pelo **mesmo ator**, o ledger.
- `AdmitLLMCall(call_id, day, cap_usd, estimate_usd)`: admite se `gasto do dia + reservas abertas + estimativa <= teto`, e nesse caso cria uma reserva.
- `estimate_usd = prompt estimado × preço de entrada + reserve_output_tokens × preço de saída`, com `reserve_output_tokens` configurável em `instance_budget` (padrão 1000).
- O registro do uso real (`RecordLLMUsage` com `call_id`) substitui a reserva pelo custo real. `ReleaseReservation(call_id)` desfaz a reserva quando a chamada falha.
- Reservas sem registro expiram em 10 minutos.
- O `/teto liberar` do admin continua funcionando: o teto efetivo do dia vem do ator `instance_budget`, e o ledger o recebe como parâmetro.

**Critérios de aceite:**
- [ ] Teste do cenário acima: duas admissões concorrentes cujas estimativas somadas passam do teto, e só uma é admitida.
- [ ] Teste: a falha do LLM libera a reserva; uma reserva expira sem registro.
- [ ] Commit: `fix(budget): reserve estimated spend at admission`.

### B-04: Uso não se perde quando a gravação falha

**Problema:** se `try_record_llm_usage` falha (por exemplo, timeout de 1,5 s), o uso real da chamada é perdido, e `daily_spend` fica abaixo do real.

**Critérios de aceite:**
- [ ] Cada chamada ao LLM tem um `call_id` único, o mesmo da B-03.
- [ ] O ledger ignora um segundo registro com o mesmo `call_id` (idempotência), inclusive quando um registro que deu timeout foi processado depois.
- [ ] Em caso de falha, o runtime tenta de novo em segundo plano: 3 tentativas, após 1 s, 5 s e 30 s. Se todas falharem, registra um audit `ledger_write_lost` com o custo e dispara o alerta `fail_closed` que já existe.
- [ ] Testes: um ledger que falha uma vez e depois responde termina com exatamente um registro; um registro duplicado com o mesmo `call_id` é ignorado.
- [ ] Commit: `fix(ledger): retry usage writes idempotently`.

### B-05: Bordas da entrega por stream

**Critérios de aceite:**
- [ ] Em `finish_stream_in_parts` (`src/supernova/channel/registry.gleam`), um erro `MESSAGE_NOT_MODIFIED` do Telegram na edição da primeira parte é tratado como sucesso, e as partes seguintes continuam sendo enviadas. Qualquer outro erro interrompe e é devolvido.
- [ ] Se o envio de uma parte seguinte falhar com limite de taxa (HTTP 429 ou `retry_after`), espere o tempo indicado, limitado a 10 s, e tente essa parte até 3 vezes. Se a entrega falhar mesmo assim, envie uma última mensagem curta, `"(Não consegui enviar o restante da resposta.)"`, sem reenviar as partes que já chegaram.
- [ ] Um `StreamUpdate` maior que o limite do canal é **ignorado**: a mensagem provisória não é editada e o conteúdo **não** é tratado como entregue. A divisão completa acontece no `StreamComplete`.
- [ ] Testes com o gravador e com o mock HTTP do Telegram para os três casos.
- [ ] Commit: `fix(registry): resilient split delivery for streamed replies`.

### B-06: Saída de grupo confirmada

**Critérios de aceite:**
- [ ] `maybe_leave_unauthorized_group` verifica o resultado de `telegram.leave_chat`. O audit "left unauthorized group" só é gravado quando a saída dá certo.
- [ ] Se a saída falhar, tente de novo em segundo plano após 5 s, 30 s e 120 s. Se falhar nas três, grave o audit `leave_failed` e dispare um alerta para os admins.
- [ ] Testes com o hook `leave_group` simulando falha e sucesso.
- [ ] Commit: `fix(registry): record group leaves only after Telegram confirms`.

### B-07: Cliques em botões

**Decisão:** clicar em botão não é conversa. Um clique passa pela checagem de acesso e de chat, mas **não** consome o rate limit nem exige orçamento de tokens.

**Critérios de aceite:**
- [ ] Crie `closed_group_runtime.gate_interaction(runtime, channel, chat_id, user_id)`, que verifica só acesso e chat e devolve `Allowed`, `Reply` ou `Ignored`. O router passa a usá-la em `handle_inbound_interaction`, no lugar de `closed_group_gate_for(..., "")`.
- [ ] A negação de um clique **não edita** a mensagem do seletor, que é compartilhada no grupo. No Telegram, responda ao callback com `answerCallbackQuery`, com o texto de negação e `show_alert`, se o adapter já tiver suporte; se não tiver, ignore o clique em silêncio e registre o audit. No Discord, responda com uma mensagem efêmera, se houver suporte; se não houver, ignore.
- [ ] Testes: um clique de membro com orçamento zerado ainda troca o modelo; um clique não consome o rate limit; um clique negado não gera edição da mensagem original no gravador.
- [ ] Commit: `fix(router): interactions check access only and never edit shared pickers on denial`.

### B-08: Encerramento ordenado

**Critérios de aceite:**
- [ ] As chaves da fila passam a incluir um identificador da instância do registry (`"<registry_id>:<canal>:<chat>"`), gerado na inicialização.
- [ ] Nova função `chat_lanes.drain(prefix, timeout_ms) -> Int`. Ela para de aceitar jobs com esse prefixo, espera os pendentes terminarem até o prazo e devolve quantos ainda restavam ao fim do prazo.
- [ ] `stop_channels` faz, nesta ordem: para o recebimento de mensagens; chama `drain(registry_id, 25_000)`, abaixo dos 30 s do `stop_grace_period` do compose; só então para o REST e as sessões. Se sobrarem jobs, registra um log `warn` com o número.
- [ ] Teste: com um job em andamento e outro na fila, `stop_channels` espera os dois antes de parar as dependências; com o prazo curto de teste, devolve o número de jobs que sobraram.
- [ ] Commit: `fix(registry): drain chat lanes before stopping channel dependencies`.

### B-09: Autorização expirada não cobra

**Problema:** se o `safe_call` da autorização der timeout, o gateway ainda pode processar o pedido depois e cobrar a chamada, embora a ferramenta nunca rode.

**Critérios de aceite:**
- [ ] `AuthorizeTool` cria uma **reserva** com id e prazo de 5 s, e a resposta inclui esse id.
- [ ] O chamador confirma a reserva (`ClaimTool(id)`) antes de executar. A cobrança no orçamento só acontece na confirmação.
- [ ] Reservas não confirmadas expiram e não cobram nada. O limite por hora conta reservas abertas mais cobranças, para que chamadas em paralelo continuem sem estourar o limite.
- [ ] Testes: autorização sem confirmação não cobra; confirmação cobra uma vez; duas autorizações em paralelo com um único crédito restante: só uma é aceita.
- [ ] Commit: `fix(gateway): charge tool calls on claim, expire unclaimed authorizations`.

### B-10: Riscos aceitos e fechamento

**Critérios de aceite:**
- [ ] Acrescente a `docs/B1_REPORT.md` a seção "Riscos aceitos", com:
  - **Worker de fila derrubado à força perde os jobs que ainda não começaram.** Aceito: a falha de um job é capturada dentro do worker, e um worker só morre se for derrubado de fora. Registre a justificativa.
- [ ] Atualize `RELEASE_NOTES_v0.4.0.md` com as correções das fases A e B. Ainda não há release v0.4.0 publicada, então não crie versão nova.
- [ ] `git push -u origin fix/b1-1-endurecimento` e abra o PR:
  - se o PR #12 já estiver mesclado: `gh pr create --base master`;
  - se não estiver: `gh pr create --base feat/grupo-fechado`.
- [ ] No corpo do PR, uma tabela história → problema → teste.
- [ ] Commit: `docs: accepted risks and v0.4.0 notes for B1.1`.

## 5. Regras de autonomia

- Não peça aprovação humana: a execução foi pré-aprovada.
- **Não** faça merge de PR, não crie tags e não publique imagens.
- Rede permitida apenas para `git fetch/pull/push` deste repositório, Hex (`gleam deps`) e `gh`.
- Nunca execute, nem em teste, comando destrutivo (`rm`, `find -delete`, `git reset`, `git clean`, `git branch -D` etc.) fora de um diretório temporário criado pelo próprio teste.
- Se um teste existente quebrar, o problema está na sua mudança, a menos que o teste fixe exatamente o comportamento que esta PRD manda mudar. Nesse caso, ajuste o teste e explique no commit.
- Se uma decisão não estiver especificada, escolha a opção mais conservadora (mais restritiva para acesso e orçamento, que preserve a ordem para concorrência) e registre-a.
- Commits pequenos, em inglês, sem `Co-Authored-By` nem crédito de IA.

## 6. Relatório final

Acrescente a `docs/B1_REPORT.md`:

- a linha de base e o estado final das duas fases: testes, cobertura e warnings;
- a lista de commits de cada fase e os links dos PRs e dos runs de CI;
- as decisões tomadas sem especificação explícita.

## 7. Métricas de sucesso

- Remover um membro do YAML e reiniciar revoga o acesso, mesmo depois de negações e comandos.
- Nenhum caminho de produção roda ferramenta de caminho sem política de workspace.
- Comandos de relatório nunca respondem em chat não autorizado.
- Nenhum comando git aceito altera o repositório nem lê fora do workspace.
- O bot nunca sai de grupo autorizado por falha de consulta.
- O compose sobe com admin definido e preserva `access.json`, o ledger e o audit log ao recriar o contêiner.
- Nenhuma fila de chat passa de 50 pendentes, e nenhum turno do mesmo chat começa antes de o anterior terminar.
- O custo estimado inclui ferramentas; o teto diário não estoura por concorrência; nenhum uso registrado se perde por falha momentânea do ledger.
- Respostas longas chegam inteiras ou avisam que ficaram incompletas.
- `stop_channels` espera os turnos em andamento.
- CI verde nos dois PRs; cobertura ≥ linha de base.
[/PRD]
