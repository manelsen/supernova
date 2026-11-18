# PRD B1.1 — rodada 2: integridade de custo, cobrança de ferramentas e desligamento

> Executor: DeepSeek 4.1 Flash. Branch: `fix/b1-1-endurecimento` (PR #13).
> Revisor: Claude, antes de qualquer merge. O executor **não** faz merge, tag nem publica imagem.

## 1. Contexto

A Fase A (PR #12) foi revisada e aprovada. A Fase B (PR #13) recebeu 4 rodadas do CodeRabbit, com 43 comentários. A revisão humana conferiu no código os achados de maior risco. Os confirmados estão neste PRD; o restante está na seção 2, como risco aceito ou trabalho futuro.

Os pontos abaixo foram **verificados** em `324c8ff`:

| # | Onde | Defeito confirmado |
|---|---|---|
| 1 | `closed_group/runtime.gleam`, `admit_llm_call` | A reserva usa o preço do **primeiro provider de `dict.values`** (ordem arbitrária), não o do modelo da chamada. |
| 2 | `executor.gleam`, `run_provider_call` | Uma reserva cobre até 3 tentativas de `retry.with_retry`. `NetworkError` é repetido, e a requisição que caiu por timeout pode ter sido cobrada pelo provider. Na falha final a reserva é **liberada**, e o custo some. |
| 3 | `closed_group/runtime.gleam`, `retry_llm_usage` | Os retries (1 s, 5 s, 30 s) usam `runtime.ledger` capturado. Se o supervisor reiniciar o ledger, todos vão para um processo morto. |
| 4 | `resource_ledger/actor.gleam`, `AdmitLLMCall` | Só conta reservas abertas do `day` informado. Uma reserva feita às 23:59 e liquidada às 00:01 cai no dia seguinte sem ter sido contada nele. O `day` vem do chamador. |
| 5 | `runtime.gleam` (~867) e `registry.gleam` (~1027) | `list_admins` devolve `[]` no timeout, e o código cai para `runtime.config.access.admins` (YAML). Um admin revogado por comando volta a receber alertas. O mesmo acontece se todos os admins forem removidos. |
| 6 | `syscall/actor.gleam`, `authorize_tool` | O ID da reserva é `timestamp_ms:dict.size(reservations)`. O tamanho diminui com claims e expirações, então o ID **se repete** no mesmo milissegundo. |
| 7 | `syscall/actor.gleam`, `authorize_tool` | `AuthorizeTool` devolve o **executor** junto com o ID. Um chamador de `authorize_tool_call` pode executar sem fazer claim, e sem pagar. |
| 8 | `syscall/actor.gleam`, `ClaimTool` | `budget_actor.record_consumption` ignora falha (`let _ = safe_call.call(...)`). Se o budget não responder, o executor é entregue sem cobrança. |
| 9 | `syscall/actor.gleam` | `claimed_tools` nunca é limpo depois de `ToolCompleted`: cresce sem limite e permite estorno tardio de uma ferramenta que já rodou. |
| 10 | `registry.gleam`, `stop_channels_with_timeout` | O drain começa com o polling do Telegram ainda ativo. Os updates buscados nesse intervalo são confirmados ao Telegram (offset avança) e recusados pela fila, e se **perdem**. |
| 11 | `supernova_chat_lanes_ffi.erl`, `drain_timeout` / `drain_cleanup` | Depois do timeout do drain o prefixo sai de `Draining` e a fila volta a aceitar jobs de um registry que está desligando. |
| 12 | `registry.gleam` | `StartHooks.turn_hard_timeout_ms` existe, mas o código usa a constante. O prazo longo de A-08 não tem teste. |

## 2. Fora de escopo (registrar em `docs/B1_1_REPORT.md` como risco aceito ou futuro)

- Matrix: limite de tamanho codificado nos edits (o canal está fora do escopo do B1).
- Discord: preservar a espera subsegundo de `retry_after`.
- TTL de reservas por relógio monotônico (hoje o relógio é de parede).
- O efeito de reduzir o teto com reservas abertas: documentar que as reservas abertas continuam valendo até liquidar ou expirar.
- IDs de chamada legados restart-safe.
- Admissão que chega depois do timeout do chamador: ela expira sozinha em 10 min. Documentar.
- Docs e CI: `docker cp`, tag SHA, `workflow_dispatch`. Corrija só se for trivial. Se não for, registre.
- Retry 429 do placeholder antes das continuações e corte do retry pelo orçamento restante: corrija se for trivial. Se não for, registre.

## 3. Quality gates

Iguais aos do `PRD-B1-1-endurecimento.md` (seção 3), incluindo:

- **Nenhum teste executa comando bloqueado.** Bloqueios se testam com `safe_shell.validate/1`.
- **Subjects:** só o processo dono recebe. Jobs e handlers criam o próprio subject de liberação.
- **Sem `process.sleep` fixo** para estabelecer estado concorrente.
- **TDD com falha registrada:** escreva o teste, confirme que **falha** pelo motivo esperado e registre a falha na mensagem de commit.
- **Um commit por história**, com a mensagem indicada. A Fase A veio num commit só, e isso não deve se repetir.
- Use o Gleam da versão do repositório (`.tool-versions`: 1.19.2) para `gleam format --check`.

## 4. Preparação

1. `cd ~/git/supernova && git status --short`. Precisa estar vazio.
2. `git fetch origin && git switch fix/b1-1-endurecimento && git pull --ff-only`
3. Se o PR #12 já tiver sido mergeado em `master`, faça `git rebase origin/master`, resolva conflitos, rode os gates e registre. Se não tiver sido, siga em cima do branch atual.
4. Registre a linha de base: testes, cobertura e `gleam --version`.

---

### R-01: Reserva pelo preço do modelo da chamada

**Desenho:** `RunContext.admit_llm` passa a receber `fn(call_id, provider_name, model, prompt_tokens)`. `run_provider_call` passa `config.name` e `config.default_model` (os mesmos usados em `record_llm_usage`). `admit_llm_call` usa `model_price(runtime, model)`. A busca do "primeiro provider" é **removida**.

**Critérios de aceite:**
- [ ] Teste: com preço padrão barato e um modelo caro em `pricing.models`, uma chamada ao modelo caro que caberia no teto pelo preço padrão é **recusada** pelo preço caro.
- [ ] Teste: a estimativa reservada para o modelo caro é igual a `pricing.cost_usd(preço_caro, prompt, reserve_output_tokens)`.
- [ ] Commit: `fix(budget): reserve LLM spend at the routed model price`.

### R-02: Cada tentativa paga é admitida e contabilizada

**Desenho:**
- Mova a admissão para **dentro** da função repetida: cada tentativa tem um `call_id` próprio (`<base>:a<N>`) e uma reserva própria. Se não houver espaço no teto, o retry para com `PolicyDenied`.
- Quando uma tentativa falha:
  - `NetworkError` (a requisição pode ter sido processada): **liquide** a reserva como uso estimado. Grave um `LLMUsage` com `completion_tokens = reserve_output_tokens`, o custo da estimativa e um `call_id` com o sufixo `:unconfirmed`. Registre um audit `llm_usage_unconfirmed`.
  - `APIError` 4xx (inclusive 429), `ConfigError` e os demais: **libere** a reserva (o provider recusou antes de processar).
  - `APIError` 5xx: libere a reserva e registre o caso no relatório como decisão (a maioria dos providers não cobra 5xx).
- `record_llm_usage` continua sendo chamado só para a tentativa bem-sucedida, com o `call_id` dela.

**Critérios de aceite:**
- [ ] Teste com um provider de teste que falha com `NetworkError` na 1ª tentativa e responde na 2ª: o ledger tem **duas** entradas (uma `:unconfirmed` e uma real), e o total do dia é a soma das duas.
- [ ] Teste: falha com 429 nas três tentativas deixa o total do dia **inalterado** e nenhuma reserva aberta.
- [ ] Teste: com o teto quase cheio, a 2ª tentativa é recusada pela admissão e o executor devolve `PolicyDenied`.
- [ ] Se o mock atual não permitir falha controlada por tentativa, crie um marcador de mock (por exemplo `[mock-network-fail-once]`) seguindo o padrão de `[mock-delay-ms=N]`.
- [ ] Commit: `fix(budget): admit and account every paid LLM attempt`.

### R-03: Retries do ledger usam o ledger vivo

**Critérios de aceite:**
- [ ] Em `retry_llm_usage`, o retry de uso de ferramenta (se houver) e a liberação final, o ledger é resolvido **em cada tentativa** via `closed_group_global` (o getter já existe em `global.gleam`), com fallback para `runtime.ledger` se o global estiver vazio.
- [ ] Confirme que o filho do supervisor que reinicia o ledger chama `set_ledger` com o novo handle. Se não chamar, corrija.
- [ ] Teste: grave um uso com o ledger parado, troque o global por um ledger novo antes do primeiro retry e confirme que o uso aparece no ledger novo. Use delays de retry reduzidos por um hook de teste, sem esperar 1 s real se puder evitar.
- [ ] Commit: `fix(ledger): resolve the live ledger on every usage retry`.

### R-04: Admissão sem buraco na virada do dia

**Desenho:**
- `AdmitLLMCall` deixa de receber `day`. O ledger calcula o dia com `state.day_key(state.now())`.
- Na conta da admissão entram **todas** as reservas abertas, de qualquer dia, porque uma reserva aberta pode ser liquidada no dia corrente. Isso é conservador por no máximo 10 min depois da meia-noite.
- `admit_llm_call` em `runtime.gleam` para de calcular `day`.

**Critérios de aceite:**
- [ ] Teste com relógio controlado: reserve às 23:59:30 do dia D com estimativa E, avance o relógio para 00:00:10 de D+1 com o total de D+1 em `cap − E/2`, e uma nova admissão de E é **recusada**.
- [ ] Teste: depois de liquidar ou liberar a reserva antiga, a mesma admissão é aceita.
- [ ] Os testes existentes de admissão continuam passando (ajuste só a assinatura).
- [ ] Commit: `fix(ledger): count every open reservation and own the day key`.

### R-05: Alertas só para admins efetivos

**Desenho:**
- Crie `access_actor.try_list_admins(access) -> Result(List(String), Nil)`, como `try_list_chats`.
- Em `runtime.gleam` (alertas de grupo) e `registry.gleam` (`alert_admins`):
  - `Ok([])`: ninguém recebe, e um log `warn` registra o caso;
  - `Ok(admins)`: envie para eles;
  - `Error(Nil)`: não envie para ninguém, registre um log `warn` e um audit `alert_dropped`.
- O fallback para `runtime.config.access.admins` é **removido** dos dois lugares.

**Critérios de aceite:**
- [ ] Teste: com YAML `admins: [A, B]` e `/acesso remover B`, um alerta chega só a A (use o `send_alert` de teste).
- [ ] Teste: com o ator de acesso sem responder, nenhum alerta é enviado e o audit `alert_dropped` aparece.
- [ ] Commit: `fix(alerts): never fall back to YAML admins`.

### R-06: Reservas de ferramenta com ID único, sem executor antes da cobrança

**Desenho:**
- ID da reserva: `"tool:" <> int.to_string(unique_integer())`, com `erlang:unique_integer([positive, monotonic])` via FFI.
- `AuthorizeTool` devolve `Result(String, String)`, **só o ID**. `authorize_tool_call` muda de tipo junto.
- `ClaimTool` só devolve `Ok(executor)` se a cobrança **confirmou**. Crie `budget_actor.try_record_consumption(...) -> Result(Nil, Nil)` e use-a. Se falhar, a reserva continua aberta, o claim devolve `Error("budget unavailable; tool call refused")` e um audit `fail_closed` é registrado.
- `ToolCompleted` passa a carregar o `reservation_id`, e o handler remove a entrada de `claimed_tools`. Depois disso, `CancelToolClaim` desse ID não estorna nada.
- O estorno de `CancelToolClaim` grava o timestamp da cobrança em `claimed_tools` e estorna na janela horária **dessa** cobrança. Se a API de budget não permitir escolher a janela, registre como risco aceito e não estorne quando a janela já virou.

**Critérios de aceite:**
- [ ] Teste: 1000 autorizações seguidas, com claims e expirações intercaladas, geram 1000 IDs distintos.
- [ ] Teste de tipo/compilação: `authorize_tool_call` não devolve executor (o teste usa o novo tipo).
- [ ] Teste: com o budget sem responder, o claim é recusado e a ferramenta **não** roda (use um executor de teste que avisa se for chamado).
- [ ] Teste: depois de `ToolCompleted`, `CancelToolClaim` do mesmo ID não altera o consumo, e `claimed_tools` fica vazio.
- [ ] Commit: `fix(gateway): unique tool reservations and charge before execution`.

### R-07: Desligamento sem perder mensagens

**Desenho:**
- Cada adaptador ganha uma forma de **parar o ingresso** (polling do Telegram, gateway do Discord) sem fechar o envio. Pode ser um campo novo em `port.ChannelAdapter` (por exemplo `stop_ingress: fn() -> Nil`, com padrão no-op), ou um hook equivalente.
- Em `stop_channels_with_timeout`: (1) pare o ingresso de todos os adaptadores; (2) faça o drain; (3) chame `adapter.stop()`.
- O polling do Telegram, ao parar, **não** confirma um offset que ainda não despachou. Se a busca em curso já trouxe updates, despache-os antes de sair do loop.
- Em `supernova_chat_lanes_ffi.erl`: depois de `drain_timeout`, o prefixo **continua** em `Draining` até o registry ser parado de vez. Crie `undrain(Prefix)` para testes e para um eventual reinício do registry.
- Valide os argumentos de `drain/2`: prefixo vazio e `TimeoutMs < 0` devolvem erro (`-1`) sem mudar o estado.
- O log de recusa não pode bloquear o gerente. Já é feito via `spawn`; mantenha e limite a 1 log por chave a cada 10 s.

**Critérios de aceite:**
- [ ] Teste (com o polling de teste/injeção do registry): um update que chega durante o desligamento ou é processado, ou não tem o offset confirmado. Nunca é confirmado e descartado.
- [ ] Teste: depois de um drain que estoura o prazo, um `submit` com o mesmo prefixo é **recusado**.
- [ ] Teste: `drain(<<>>, 100)` e `drain(<<"x">>, -1)` devolvem `-1`.
- [ ] Commit: `fix(shutdown): stop ingress before draining chat lanes`.

### R-08: Prazo longo do turno com teste

**Critérios de aceite:**
- [ ] `await_late_terminal` usa `hooks.turn_hard_timeout_ms`, não a constante. A constante vira só o valor padrão de `no_start_hooks`.
- [ ] Teste: com `stream_timeout_ms` pequeno e `turn_hard_timeout_ms` pequeno, um turno sem evento terminal libera a fila depois do prazo longo e registra o log `error`. Um segundo turno do mesmo chat roda em seguida.
- [ ] Commit: `test(lanes): cover the hard turn timeout through start hooks`.

### R-09: Respostas a achados desatualizados de acesso

O CodeRabbit pediu para limpar `added` ao revogar e `removed` ao reconceder. `adjust_list` (`src/supernova/core/access/pure.gleam`) parece já fazer isso.

**Critérios de aceite:**
- [ ] Teste de reinício: `/acesso adicionar X admin` (X fora do YAML), reinicie, X é admin; `/acesso remover X`, reinicie, X é negado e `access.json` não tem X em `added` nem em `removed`.
- [ ] Teste de reinício: YAML `members: [M]`, `/acesso remover M`, `/acesso adicionar M`, reinicie, M é permitido e `removed` não tem M.
- [ ] Callback negado mantém o audit e o contador de abuso. Se não mantiver, corrija; se mantiver, cubra com teste.
- [ ] Se algum teste falhar, corrija o código. Se todos passarem de primeira, registre isso no commit (é um teste de regressão, não um TDD).
- [ ] Commit: `test(access): restart coverage for command-only grants and revokes`.

### R-10: Fechamento

**Critérios de aceite:**
- [ ] Atualize `docs/B1_1_REPORT.md` com:
  - uma seção "Rodada 2", com a tabela defeito → correção → teste;
  - a lista de riscos aceitos da seção 2;
  - as respostas aos comentários desatualizados.
- [ ] Rode todos os gates e registre testes e cobertura antes e depois.
- [ ] `git push origin fix/b1-1-endurecimento` e aguarde o CI do PR #13. Se falhar, corrija e repita.
- [ ] **Não** responda nem resolva threads do CodeRabbit em nome do mantenedor. Liste no relatório quais threads cada commit endereça.
- [ ] Commit: `docs: record B1.1 review round 2`.

---

## 5. Regras de autonomia

- Se uma história exigir mudar uma API pública além do descrito aqui, faça a menor mudança possível e registre no relatório.
- Se um critério se mostrar impossível ou errado diante do código, **não invente**: registre no relatório com a evidência e siga para a próxima história.
- Não toque em `blackboard` nem em `memory_federation`.
- Não faça merge, tag, release nem publicação de imagem.

## 6. Métricas de sucesso

- Nenhum caminho entrega executor de ferramenta sem cobrança confirmada.
- Toda tentativa de LLM que pode ter sido cobrada aparece no ledger.
- O teto diário não estoura por concorrência, retry nem virada do dia, salvo pelo erro das estimativas.
- Nenhum update é perdido no desligamento.
- Testes e cobertura iguais ou maiores que a linha de base. CI verde no PR #13.
