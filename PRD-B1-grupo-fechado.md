[PRD]
# PRD B1: Grupo fechado e kernel ligado

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar. Execute as histórias **na ordem**. Cada história termina com os quality gates verdes e um commit próprio.
>
> **Dimensionamento:** 19 histórias, cerca de 7 horas de execução. Se a sessão for interrompida, retome pela primeira história sem commit, conferindo `git log --oneline` contra os títulos de commit de cada história.

## 1. Contexto

A Supernova v0.3.0 está verde (2007 testes, cobertura de 74,56%, CI restaurado) e o Agente Companheiro (`PRD.md`) está implementado. Decisões do mantenedor em 18/11/2026:

- **Público:** um **grupo fechado** de pessoas convidadas.
- **Canais suportados:** **Telegram e Discord**. Os outros 7 continuam no código como experimentais.
- **Deploy:** ainda indefinido. A única premissa é Docker.
- **Imagem no GHCR:** publicar **apenas em tags `v*`**.

Lacunas encontradas no código em 18/11:

1. **Não há controle de acesso.** Qualquer pessoa que encontre o bot conversa com ele e gasta a conta de API do mantenedor. A experiência com a Amélie mostrou que isso atrai abuso.
2. **O orçamento existe, mas está desligado.** `src/supernova/core/budget_policy/` está implementado, e `ExecutorConfig` tem `budget_policy: Option(...)` e `budget_agent_id`, mas nenhum ponto de produção passa `Some(...)`.
3. **A mediação é incompleta.** O `SyscallGateway` (`src/supernova/core/syscall/actor.gleam`, com workspace policy, capabilities, ledger e auditoria) só é usado pela ferramenta `gateway`. As outras ferramentas são chamadas diretamente pelo executor.
4. **A identidade usada para o orçamento é ambígua.** No Telegram, `resolve_session(channel_id, _user_id)` ignora o usuário (`src/supernova/adapters/telegram_router.gleam:187`). Num grupo, todos compartilham a sessão. O orçamento precisa ser **por pessoa**, independentemente da sessão.
5. `.github/workflows/docker.yml` publica no GHCR a cada push na `master`.
6. `src/supernova/tools/git_inspect.gleam` chama `safe_shell.execute("git ...")`, mas `git` não está na lista de permitidos, então essas funções sempre falham.

**Objetivo:** só pessoas autorizadas usam a Supernova; cada pessoa tem um orçamento imposto pelo kernel; toda ferramenta passa pelo `SyscallGateway`; Telegram e Discord ficam cobertos de ponta a ponta com mocks.

## 2. Fora de escopo

- O self: constituição, metas próprias, loop de introspecção, auto-modelo calibrado. Isso fica para a **PRD B2**.
- A convivência entre agentes: mensagens entre agentes, contatos mútuos, contexto filtrado e cobrança cruzada. Isso fica para a **PRD B3**. Nesta PRD, só se garante que nenhuma memória compartilhada seja ligada antes disso (US-010).
- Novos canais, providers ou ferramentas.
- Remover os canais experimentais.
- Deploy em servidor, tags de release, publicação de imagens e merge do PR final.
- Alterar `PRD.md` ou `PRD-retomada.md`.

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

- **Segurança dos testes (obrigatória):** nenhum teste pode **executar** um comando que deveria ser bloqueado. Teste bloqueios chamando funções de **validação** (por exemplo, `safe_shell.validate/1`), nunca a execução. Em 17/11, um teste que chamava `safe_shell.execute("find . -delete")` antes de o bloqueio existir apagou o repositório inteiro.
- Testes não usam rede real, tokens reais, Postgres real nem Chromium real. HTTP de canais e de LLM é sempre mock.
- TDD: teste que falha → implementação → teste passa. Registre a falha inicial no commit.
- Lógica nova vai em funções puras (padrão `types` / `pure` / `actor` de `src/supernova/core/`). Atores só fazem I/O e estado.
- A cobertura não pode cair. Cada história deixa `make coverage` ≥ ao valor do início da história.

## 4. Preparação

1. `cd ~/git/supernova && git status --short`. Precisa estar vazio. Se não estiver, **pare** e registre.
2. `git fetch origin && git switch master && git pull --ff-only`
3. Confirme que o PR #11 (`fix/safe-shell-no-shell`) foi mesclado: `git log --oneline -20 | grep -i "safe_shell"`. Se não foi, **pare** e registre.
4. `git switch -c feat/grupo-fechado`
5. Registre a linha de base: testes, cobertura e `gleam --version`.

## 5. Histórias de usuário

### US-001: Publicar no GHCR só em tags

**Critérios de aceite:**
- [ ] `.github/workflows/docker.yml`: o evento `push` dispara **só** em `tags: ['v*']`. Remova `push.branches`.
- [ ] O build em `pull_request` para `master` continua, sem push (`push: ${{ github.event_name != 'pull_request' }}` já garante isso).
- [ ] Em `metadata-action`, remova `type=ref,event=branch` e `type=sha`. Mantenha `type=semver,pattern={{version}}` e acrescente `type=semver,pattern={{major}}.{{minor}}`.
- [ ] Atualize a seção de imagens do `DEPLOY.md`: a imagem `:master` deixa de ser publicada.
- [ ] Commit: `ci: publish container images only on version tags`.

### US-002: `git_inspect` funcional e somente leitura

**Critérios de aceite:**
- [ ] `git` entra na lista de permitidos do `safe_shell` **apenas** com os subcomandos `status`, `log`, `branch`, `diff` e `show`. Qualquer outro subcomando (`push`, `commit`, `reset`, `checkout`, `clean`, `config`, `-c`, `--exec-path` etc.) é rejeitado em `validate/1` com `"Blocked: git subcommand not allowed: <sub>"`.
- [ ] Opções globais antes do subcomando (`git -C x status`, `git -c k=v log`) são rejeitadas.
- [ ] Testes de rejeição usam **somente** `safe_shell.validate/1`.
- [ ] Teste de execução: `git_inspect.status()` (ou equivalente) devolve `Ok` dentro de um repositório git temporário criado pelo teste em `/tmp`. **Não** rode `git` no repositório do projeto.
- [ ] Commit: `fix(git_inspect): allow read-only git subcommands`.

### US-003: Identidade de quem fala, separada da sessão

**Critérios de aceite:**
- [ ] Crie `src/supernova/core/principal.gleam` (puro) com `pub type Principal { Principal(channel: String, user_id: String) }` e `pub fn principal_id(p) -> String` no formato `"<channel>:<user_id>"` (ex.: `"telegram:123"`, `"discord:456"`).
- [ ] Os routers do Telegram e do Discord extraem o `user_id` do remetente de cada mensagem e o propagam até o executor. A sessão (`resolve_session`) **não muda**.
- [ ] O executor recebe o `Principal` e usa `principal_id` como `budget_agent_id`.
- [ ] Mensagens sem remetente identificável (por exemplo, posts de canal no Telegram) são descartadas com log `warn`, sem chamar o LLM.
- [ ] Testes cobrem: DM no Telegram, grupo no Telegram com dois usuários na mesma sessão gerando dois principals diferentes, DM e servidor no Discord, e mensagem sem remetente.
- [ ] Commit: `feat(core): carry the speaking principal separately from the session`.

### US-004: Lista de acesso (negar por padrão)

**Critérios de aceite:**
- [ ] Configuração nova em `src/supernova/config.gleam`, documentada em `supernova.yaml.example`:
  ```yaml
  access:
    mode: allowlist          # allowlist | open
    admins: ["telegram:123"]
    members: ["discord:456"]
    denied_reply: "Esta instância é privada."
  ```
  Com override por env: `SUPERNOVA_ACCESS_ADMINS` e `SUPERNOVA_ACCESS_MEMBERS`, listas separadas por vírgula.
- [ ] **O padrão é `allowlist` com listas vazias.** Uma instância nova não responde a ninguém até ser configurada. Isso é registrado no boot com log `warn`: `access: allowlist is empty, nobody can use this instance`.
- [ ] Crie `src/supernova/core/access/` com `types.gleam`, `pure.gleam` (`decide(config, principal) -> Allowed(Role) | Denied`, com `Role = Admin | Member`) e `actor.gleam`, que guarda as listas em memória e persiste as alterações de runtime em `<data_dir>/access.json`.
- [ ] A checagem acontece no router, **antes** de qualquer chamada ao LLM, a ferramentas ou à memória. Um principal negado recebe `denied_reply` no máximo **uma vez a cada 24 h por principal** (anti-spam) e gera um registro no audit log com `action: "access_denied"`.
- [ ] Comandos de admin (só para `Admin`): `/acesso listar`, `/acesso adicionar <principal> [admin|membro]`, `/acesso remover <principal>`. Um admin não pode remover a si mesmo se for o último admin.
- [ ] Testes: o padrão nega; membro passa; admin passa; o modo `open` libera; os comandos de admin alteram e persistem as listas; um membro não consegue usar `/acesso`; a resposta de negação respeita o limite de 24 h; nenhuma chamada ao LLM mock acontece para quem foi negado.
- [ ] Commit: `feat(access): deny-by-default allowlist with admin commands`.

### US-005: Orçamento por pessoa, ligado em produção

**Critérios de aceite:**
- [ ] Configuração nova:
  ```yaml
  budget:
    member: { tokens_per_hour: 50000, tool_calls_per_hour: 60 }
    admin:  { tokens_per_hour: -1,    tool_calls_per_hour: -1 }   # -1 = ilimitado
  ```
  Mapeie para o `BudgetConfig` existente em `src/supernova/core/budget_policy/types.gleam`. Se faltar campo, crie-o seguindo o padrão do módulo.
- [ ] Na inicialização da aplicação (`src/supernova.gleam`), o ator `budget_policy` é iniciado sob o supervisor de infraestrutura, junto com metrics, tracing e os demais.
- [ ] **Todo** `ExecutorConfig` montado em produção recebe `budget_policy: Some(...)` e `budget_agent_id: Some(principal_id)`. Teste de arquitetura: um teste que lê os arquivos de `src/` e falha se encontrar `budget_policy: None` fora de `test/`.
- [ ] Antes de **cada** chamada ao LLM, o executor verifica o orçamento. Se estiver esgotado, **não chama** o LLM e responde em português: `"Seu limite de uso desta hora acabou. Ele renova às HH:MM."`, com o horário calculado a partir da janela.
- [ ] Depois de cada chamada ao LLM, os tokens reais da resposta (`usage`, ou uma estimativa por caracteres quando o provider não informar) são registrados com `record_consumption`.
- [ ] Cada chamada de ferramenta consome 1 de `tool_calls_per_hour`.
- [ ] Testes com LLM mock: um membro esgota o orçamento e recebe a mensagem sem nova chamada ao mock; um admin com `-1` nunca é bloqueado; a janela reinicia; dois membros no mesmo grupo do Telegram têm orçamentos independentes.
- [ ] Commit: `feat(budget): enforce per-principal budgets in production`.

### US-006: Ledger e `/uso`

**Critérios de aceite:**
- [ ] O `resource_ledger` (`src/supernova/core/resource_ledger/`) registra, por `principal_id`: chamadas ao LLM (provider, modelo, tokens de entrada e saída) e chamadas de ferramenta (nome, resultado ok ou erro). Se o ledger ainda não estiver iniciado em produção, inicie-o sob o supervisor de infraestrutura.
- [ ] Comando `/uso` (todos): mostra o consumo da pessoa na janela atual e nas últimas 24 h, em português, com tokens e chamadas de ferramenta.
- [ ] Comando `/uso todos` (só admin): uma tabela com os principals ordenados por tokens nas últimas 24 h.
- [ ] O ledger persiste em `<data_dir>/ledger/` (um arquivo JSON Lines por dia) e sobrevive a reinício. Arquivos com mais de 30 dias são removidos no boot.
- [ ] Testes: o registro acontece; `/uso` mostra só os dados da própria pessoa; um membro recebe recusa em `/uso todos`; os dados sobrevivem a um reinício do ator (recriar o ator lendo os arquivos de um diretório temporário); a rotação de 30 dias funciona.
- [ ] Commit: `feat(ledger): per-principal usage ledger with /uso`.

### US-007: Toda ferramenta passa pelo `SyscallGateway`

**Critérios de aceite:**
- [ ] O executor deixa de chamar módulos de `src/supernova/tools/*` diretamente. Toda execução de ferramenta passa por uma única função do `SyscallGateway` (por exemplo, `syscall_actor.invoke_tool(gateway, principal, tool_name, args)`), que aplica, nesta ordem: capability manifest → workspace policy (quando a ferramenta mexe com caminho) → orçamento (`tool_calls_per_hour`) → execução → ledger → audit log.
- [ ] Teste de arquitetura: um teste que lê `src/supernova/core/executor.gleam` e falha se houver `import supernova/tools/` (com exceção de importar apenas tipos ou definições de ferramenta, se isso for necessário para montar a lista; documente a exceção no teste).
- [ ] O comportamento das ferramentas não muda para quem tem permissão. Todos os testes existentes do executor continuam passando.
- [ ] Commit: `refactor(kernel): route every tool call through the syscall gateway`.

### US-008: Capabilities por papel

**Critérios de aceite:**
- [ ] Configuração nova:
  ```yaml
  capabilities:
    member: { allowed: ["web", "file_system", "canvas", "github"], denied: ["safe_shell", "process", "browser", "gateway"] }
    admin:  { allowed: ["*"], denied: [] }
  ```
- [ ] O `capability_manifest` existente é carregado a partir dessa configuração, por papel. Um principal herda o manifesto do próprio papel.
- [ ] Ferramentas negadas **não aparecem** na lista de ferramentas enviada ao LLM para aquele principal, e uma tentativa de chamá-las mesmo assim é recusada pelo gateway e registrada no audit log com `action: "capability_denied"`.
- [ ] O padrão para `member` nega as ferramentas com risco de execução ou custo alto (`safe_shell`, `process`, `browser`, `gateway`).
- [ ] Testes: a lista de ferramentas de um membro não contém as negadas; uma chamada forçada a uma ferramenta negada é recusada; um admin vê todas.
- [ ] Commit: `feat(capabilities): role-based tool manifests`.

### US-009: Telegram e Discord suportados; os demais experimentais

**Critérios de aceite:**
- [ ] Em `src/supernova/config.gleam`, cada canal tem um nível de suporte: `supported` para Telegram e Discord e `experimental` para os outros 7.
- [ ] No boot, cada canal experimental habilitado gera um log `warn`: `channel <nome> is experimental: not covered by end-to-end tests`.
- [ ] Testes de ponta a ponta **com HTTP mock**, um arquivo por canal (`test/e2e/telegram_e2e_test.gleam` e `test/e2e/discord_e2e_test.gleam`), cobrindo o fluxo completo desde o update de entrada até a resposta enviada:
  - membro autorizado recebe resposta;
  - não autorizado recebe `denied_reply` uma vez e nada mais;
  - orçamento esgotado gera a mensagem de limite;
  - ferramenta negada a membro é recusada;
  - resposta longa é dividida respeitando o limite do canal (4096 caracteres no Telegram, 2000 no Discord);
  - erro do LLM gera mensagem amigável em português.
- [ ] Atualize `README.md` e `STATUS.md` com a tabela de suporte por canal.
- [ ] Commit: `test(e2e): cover supported channels end to end; mark others experimental`.

### US-010: Impedir o compartilhamento de memória entre agentes

**Por quê:** cada pessoa terá a sua agente, e as agentes só poderão trocar informações por mensagens mediadas pelo kernel, no limite do necessário (PRD B3). Dois módulos existentes fazem o contrário: `src/supernova/core/blackboard.gleam` é um armazenamento chave-valor compartilhado **sem controle de acesso**, e `src/supernova/core/memory_federation/` **promove fatos locais para o world model global só por relevância**. Em 18/11, nenhum dos dois estava ligado ao fluxo de produção. Esta história garante que continuem assim até a B3 definir o controle de acesso.

**Critérios de aceite:**
- [ ] Confirme o estado atual: `rg -n "core/blackboard|memory_federation" src --glob '!src/supernova/core/blackboard.gleam' --glob '!src/supernova/core/memory_federation/**'`. Em 18/11 a saída era:
  - `src/supernova/core/project/actor.gleam` importa `blackboard`. É o orquestrador de projetos: recebe um `Option(Blackboard)` injetado para registrar o andamento das tarefas dos sub-agentes de **um mesmo dono**. Uso legítimo.
  - `src/supernova/core/kernel_version/pure.gleam` só **cita o nome** `memory_federation` numa lista de capabilities, sem importar o módulo.
  Se a saída tiver qualquer outro arquivo, **não remova nada**: pare a história, registre no relatório e siga para a próxima.
- [ ] Confirme que o orquestrador de projetos não é iniciado em produção: `rg -n "core/project/actor" src` deve retornar vazio (fora do próprio módulo). Registre o resultado no commit.
- [ ] Crie `test/architecture/isolation_test.gleam` com um teste que lê os arquivos `.gleam` de `src/` e **falha** se qualquer arquivo importar `supernova/core/blackboard` ou `supernova/core/memory_federation`, exceto:
  - os próprios módulos (`src/supernova/core/blackboard.gleam` e `src/supernova/core/memory_federation/**`);
  - `src/supernova/core/project/actor.gleam`, com o comentário: `"same-owner orchestration: the blackboard is injected per project and must never be shared across principals"`.
  Cada exceção fica numa lista explícita no teste, com o comentário do motivo. Citar o nome em string, como faz `kernel_version`, não é import e não precisa de exceção.
- [ ] Um segundo teste no mesmo arquivo falha se algum arquivo de `src/`, fora de `src/supernova/core/project/`, importar `supernova/core/project/actor`. Assim o orquestrador, e com ele o blackboard, não entra em produção sem revisão. Mensagem: `"project orchestrator uses a blackboard; wire it only after PRD B3 defines per-principal isolation"`.
- [ ] A mensagem de falha do teste explica a regra: `"blackboard/memory_federation share memory across agents without access control; wire them only through the syscall gateway after PRD B3"`.
- [ ] Acrescente um comentário de módulo no topo de `blackboard.gleam` e de `memory_federation/types.gleam` com a mesma regra, apontando para o teste.
- [ ] Prove que o teste funciona: adicione temporariamente `import supernova/core/blackboard` em `src/supernova.gleam`, confirme que o teste falha, reverta e cite isso no commit.
- [ ] Commit: `test(architecture): forbid wiring shared agent memory before access control`.

### US-011: Falhar fechado

**Por quê:** se o ator de acesso, de orçamento ou do ledger cair, o comportamento seguro é **negar**, não liberar.

**Critérios de aceite:**
- [ ] Os atores `access`, `budget_policy` e `resource_ledger` ficam sob o supervisor de infraestrutura (`OneForOne`), com reinício automático.
- [ ] Toda chamada a esses atores a partir do router ou do executor usa timeout explícito (no máximo 2 s). Em timeout, ator morto ou erro, a decisão é **negar**: acesso negado, orçamento considerado esgotado, ou chamada ao LLM ou à ferramenta recusada se o ledger não puder registrar.
- [ ] A pessoa recebe, em português: `"Estou com um problema interno e não posso responder agora. Tente de novo em alguns minutos."` Nenhum detalhe técnico vai para ela.
- [ ] Cada recusa por falha gera um log `error` e um registro no audit log com `action: "fail_closed"` e o nome do componente.
- [ ] Testes: matar cada um dos três atores durante uma conversa mock leva à recusa sem chamada ao LLM; depois do reinício pelo supervisor, a conversa seguinte funciona; o timeout é respeitado (use um ator falso que não responde).
- [ ] Commit: `feat(kernel): fail closed when access, budget or ledger are unavailable`.

### US-012: Teto global diário da instância

**Por quê:** os orçamentos individuais somados ainda podem esgotar a conta do mantenedor. É preciso um disjuntor para a instância inteira.

**Critérios de aceite:**
- [ ] Crie `src/supernova/llm/pricing.gleam` (puro) com uma tabela de preços por modelo (USD por 1 milhão de tokens de entrada e de saída), configurável no YAML:
  ```yaml
  pricing:
    default: { input_per_mtok: 1.0, output_per_mtok: 4.0 }
    models:
      "openrouter/some-model": { input_per_mtok: 0.5, output_per_mtok: 1.5 }
  instance_budget:
    daily_usd: 5.0          # -1 = sem teto
    timezone: "America/Sao_Paulo"
  ```
  Modelos sem preço usam `default`. Não invente preços reais de providers no código: o padrão é só o `default` acima, e o mantenedor preenche os demais.
- [ ] O ledger passa a registrar o custo estimado de cada chamada ao LLM.
- [ ] Antes de cada chamada ao LLM, o kernel soma o custo estimado do dia (no fuso configurado). Se `daily_usd` foi atingido, **ninguém** chama o LLM, nem os admins, até a virada do dia. A resposta é: `"O limite diário desta instância foi atingido. Volto amanhã."`
- [ ] Um admin pode liberar o teto até o fim do dia com `/teto liberar <usd>`, que eleva o teto do dia corrente. O comando fica registrado no audit log.
- [ ] `/uso` passa a mostrar o custo estimado da pessoa; `/uso todos` mostra também o total do dia e o teto.
- [ ] Testes: o cálculo de custo com e sem preço do modelo; o bloqueio ao atingir o teto; a virada do dia no fuso configurado (injete o relógio, sem depender da hora real); `/teto liberar` só para admin.
- [ ] Commit: `feat(budget): instance-wide daily spend cap with cost estimates`.

### US-013: Limite de mensagens por minuto (anti-flood)

**Critérios de aceite:**
- [ ] Configuração: `rate_limit: { member: { messages_per_minute: 10 }, admin: { messages_per_minute: -1 } }`.
- [ ] Implementação pura de janela deslizante em `src/supernova/core/rate_limit/pure.gleam`, com estado num ator (ou dentro do ator de acesso, se for mais simples), por `principal_id`.
- [ ] Mensagens acima do limite são descartadas **antes** do LLM. A pessoa recebe no máximo **um** aviso por minuto: `"Muitas mensagens seguidas. Espere um pouco."`
- [ ] Comandos de admin e `/eu` não contam para o limite.
- [ ] Testes com relógio injetado: o limite é aplicado; a janela desliza; o aviso é único por minuto; admin com `-1` não é limitado.
- [ ] Commit: `feat(access): per-principal message rate limit`.

### US-014: Chats e servidores autorizados

**Por quê:** alguém de fora pode adicionar o bot ao próprio grupo do Telegram ou servidor do Discord e provocar respostas e custos.

**Critérios de aceite:**
- [ ] Configuração: `access.allowed_chats: ["telegram:-100123", "discord:guild:789"]`. Conversas privadas com membros autorizados são sempre permitidas. Grupos e servidores só são permitidos se estiverem na lista. **O padrão é a lista vazia**, ou seja, só conversas privadas.
- [ ] Em grupo ou servidor não autorizado, o bot não responde a ninguém, nem a membros, e registra no audit log `action: "chat_denied"` uma vez a cada 24 h por chat.
- [ ] No Telegram, ao ser adicionado a um grupo não autorizado (update `my_chat_member`), o bot sai do grupo com `leaveChat` e registra no audit log. No Discord, só ignora; não sai de servidores automaticamente.
- [ ] Comandos de admin: `/acesso chat adicionar <id>`, `/acesso chat remover <id>`, `/acesso chat listar`, persistidos em `access.json`. Um admin pode usar `/eu` dentro de um grupo para descobrir o id do chat.
- [ ] Testes com HTTP mock: conversa privada com membro passa; grupo não autorizado é ignorado mesmo com membro falando; o bot sai do grupo do Telegram não autorizado; os comandos alteram e persistem a lista.
- [ ] Commit: `feat(access): restrict group chats and servers to an allowlist`.

### US-015: Alertas para os admins

**Critérios de aceite:**
- [ ] Use o módulo existente `src/supernova/core/alerts/` para gerar alertas nestes eventos:
  - um membro atinge 80% do orçamento da hora;
  - o custo do dia da instância atinge 80% do teto global, e depois 100%;
  - mais de 5 tentativas negadas (`access_denied` ou `chat_denied`) em 10 minutos;
  - qualquer `fail_closed`.
- [ ] Os alertas são enviados em mensagem privada a todos os admins pelo canal em que cada admin está cadastrado (Telegram ou Discord), no máximo **um alerta por tipo e por sujeito a cada hora** (deduplicação pura e testada).
- [ ] O texto é curto e em português, por exemplo: `"⚠️ telegram:123 usou 80% do limite da hora."`
- [ ] Testes com relógio injetado e HTTP mock: cada gatilho gera o alerta; a deduplicação funciona; admins de canais diferentes recebem pelo próprio canal.
- [ ] Commit: `feat(alerts): notify admins of budget, abuse and fail-closed events`.

### US-016: Auditoria consultável

**Critérios de aceite:**
- [ ] Confirme como `src/supernova/core/audit_log/actor.gleam` grava o arquivo com rotação (local e formato) e registre isso no commit.
- [ ] Todos os eventos novos desta PRD (`access_denied`, `chat_denied`, `capability_denied`, `fail_closed`, comandos `/acesso` e `/teto`) vão para esse audit log com `principal_id`, horário e detalhe.
- [ ] Comando `/auditoria [n]` (só admin): mostra os últimos `n` eventos (padrão 20, máximo 100) em formato compacto, mais recentes primeiro.
- [ ] Comando `/auditoria <principal>` (só admin): filtra os eventos de um principal.
- [ ] Nenhum conteúdo de mensagem de usuário é gravado no audit log, só o tipo do evento e os metadados. Teste que confirma isso.
- [ ] Testes: os eventos aparecem; o filtro funciona; um membro recebe recusa; o limite de 100 é respeitado.
- [ ] Commit: `feat(audit): admin audit queries`.

### US-017: Validar a configuração no boot

**Critérios de aceite:**
- [ ] Crie `src/supernova/config_check.gleam` (puro), com `check(config) -> List(ConfigIssue)` e `ConfigIssue(level: Error | Warning, message: String)`, cobrindo pelo menos:
  - `Error`: um `principal_id` mal formado em `admins`, `members` ou `allowed_chats` (formato `<canal>:<id>`, com canal `telegram` ou `discord`);
  - `Error`: um nome de ferramenta em `capabilities` que não existe no `tool_registry`;
  - `Error`: um valor negativo diferente de `-1` em orçamento, teto ou rate limit;
  - `Warning`: `allowlist` com `admins` vazio;
  - `Warning`: um canal experimental habilitado;
  - `Warning`: `instance_budget.daily_usd = -1`.
- [ ] Na inicialização, qualquer `Error` impede o boot, com uma mensagem clara listando todos os problemas; cada `Warning` vira um log `warn`.
- [ ] Novo subcomando `bin/supernova check-config [caminho]` (e o alvo `make check-config`), que imprime os problemas e sai com código 1 se houver `Error`.
- [ ] Testes para cada regra e para o código de saída.
- [ ] Commit: `feat(config): validate access, budget and capability config at boot`.

### US-018: Cobertura de volta ao caminho dos 85%

**Critérios de aceite:**
- [ ] Rode `make coverage` e pegue os 15 módulos com menor cobertura listados pelo escript, ignorando FFI de canais experimentais e módulos que exigem rede real.
- [ ] Escreva testes para esses módulos até a cobertura total chegar a **pelo menos 78%**. Os testes devem verificar comportamento, não só executar linhas.
- [ ] Suba o `--threshold` no `Makefile` para 78.
- [ ] Se 78% não for alcançável sem testes artificiais, pare no maior valor honesto alcançado, fixe o threshold nesse valor arredondado para baixo e registre o motivo.
- [ ] Commit: `test: raise line coverage toward 85%`.

### US-019: Documentação de operação do grupo fechado

**Critérios de aceite:**
- [ ] Nova seção em `DEPLOY.md`, "Grupo fechado", explicando: como descobrir o próprio `principal_id` (o bot responde ao comando `/eu` mesmo para quem não está autorizado, sem chamar o LLM e sem contar no limite de 24 h da negação), como cadastrar o primeiro admin por env, como convidar membros, como autorizar grupos e servidores, e como ajustar orçamento, teto diário, preços, rate limit e capabilities.
- [ ] Uma tabela de referência de todos os comandos desta PRD (`/eu`, `/uso`, `/uso todos`, `/acesso …`, `/acesso chat …`, `/teto liberar`, `/auditoria …`), com quem pode usar cada um.
- [ ] Um `supernova.yaml.example` completo e comentado com todas as seções novas, que passe em `bin/supernova check-config`. Um teste garante isso.
- [ ] Implemente `/eu` conforme descrito acima, com teste.
- [ ] `gleam.toml`: `version = "0.4.0"`. Crie `RELEASE_NOTES_v0.4.0.md` e atualize `STATUS.md`.
- [ ] Commit: `docs: closed-group operations and v0.4.0 notes`.

## 6. Regras de autonomia

- Não peça aprovação humana: a execução foi pré-aprovada.
- Rede permitida apenas para `git fetch/pull/push` deste repositório, Hex (`gleam deps`) e GitHub Actions/`gh`.
- **Não** crie tags, **não** publique imagens e **não** faça merge do PR.
- Se um teste existente quebrar, o problema está na sua mudança: corrija a mudança.
- Nunca execute, nem em teste, um comando destrutivo (`rm`, `find -delete`, `git reset`, `git clean` etc.) fora de um diretório temporário criado pelo próprio teste.
- Se uma decisão não estiver especificada, escolha a opção mais conservadora (mais restritiva para acesso, orçamento e capabilities) e registre.
- Commits pequenos, em inglês, sem `Co-Authored-By` nem crédito de IA.
- Ao terminar: `git push -u origin feat/grupo-fechado` e `gh pr create --base master` com o resumo do relatório.

## 7. Relatório final

Crie `docs/B1_REPORT.md` com:

- a linha de base e o estado final (testes, cobertura, warnings);
- o diagrama, em texto, do caminho de uma mensagem: canal → acesso → principal → orçamento → LLM → gateway → ferramenta → ledger e audit log;
- a tabela de padrões de segurança: acesso, orçamento e capabilities por papel;
- as decisões tomadas sem especificação explícita;
- a branch, os commits, o PR e o run de CI.

## 8. Métricas de sucesso

- Uma instância nova, sem configuração de acesso, não responde a ninguém e não chama o LLM.
- Uma pessoa não autorizada nunca gera uma chamada ao LLM e recebe no máximo uma resposta de negação por dia.
- Todo `ExecutorConfig` de produção tem orçamento; o teste de arquitetura impede regressão.
- Toda ferramenta passa pelo `SyscallGateway`; o teste de arquitetura impede regressão.
- Um membro não vê nem consegue chamar `safe_shell`, `process`, `browser` ou `gateway`.
- `/uso` funciona para todos e `/uso todos` só para admins.
- Telegram e Discord têm testes de ponta a ponta com mocks; os outros canais avisam no boot que são experimentais.
- O GHCR recebe imagem só em tag `v*`.
- `blackboard` e `memory_federation` não estão ligados em produção, e um teste de arquitetura impede que sejam ligados antes da PRD B3.
- Se acesso, orçamento ou ledger estiverem indisponíveis, nada é liberado (falha fechado).
- A instância nunca passa do teto diário em USD sem a liberação explícita de um admin.
- O bot não responde em grupos ou servidores não autorizados, e sai de grupos do Telegram não autorizados.
- Os admins recebem alertas de orçamento, abuso e falhas, sem duplicação dentro de uma hora.
- Uma configuração inválida impede o boot; `check-config` aponta os problemas.
- Cobertura ≥ 78% (ou o máximo honesto registrado), com o threshold atualizado.
- CI verde; cobertura ≥ linha de base.
[/PRD]
