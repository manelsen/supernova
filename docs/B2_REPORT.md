# B2 — um self por pessoa

Implementação do `PRD-B2-um-self-por-pessoa.md` nas fases A e B. A fase C não foi executada.

## Fase A

### Histórias → testes

| História | Testes |
|---|---|
| A-01 canal `sim` | `test/e2e/sim_e2e_test.gleam`: boot sem token, 401 sem/ com token errado, membro recebe resposta, não membro recebe a negação uma vez e depois silêncio, dois chats em paralelo, nascimento e prompt. |
| A-02 verificador | `test/sim/invariants_test.gleam` cobre I1–I6 e o JSON de saída; CLI executada sobre a evidência E2E (JSON abaixo). |
| A-03 identidade por principal | `test/core/agent_identity_test.gleam`: caminhos por canal, codificação segura, ida e volta, principal de sessão. |
| A-04 `self` fora do alcance | `test/core/syscall/actor_test.gleam`: leitura/escrita no próprio workspace permitida; `../self`, `self/` absoluto e workspace de outro principal negados. |
| A-05 sessão por pessoa | `test/channel/session_test.gleam`, `test/adapters/channel_router_test.gleam` e `sim_group_prompts_are_per_person_test` (prompt de B sem o segredo de A, verificado por I6). |

### Números

| Métrica | Antes | Depois |
|---|---|---|
| Testes | 2225 | 2270 |
| Cobertura de linhas | 76,01% (10667/14034) | 76,09% (11242/14774) |

A cobertura "antes" foi medida em worktree limpo no commit base `fb589c6`. O gate do repositório é 75%.

### Comportamento

- `agent_id` é `<canal>:<user_id>`; o diretório é `<data_dir>/agents/<principal codificado>/{workspace,self}`.
- No modo grupo fechado, `SUPERNOVA_WORKSPACE_ROOT` é ignorado e gera um `ConfigIssue` de warning.
- `sim` sobe com `enabled: true` **e** token não vazio; todos os endpoints exigem `Authorization: Bearer`.
- O verificador devolve `{invariants: [...]}` e sai com código 1 quando há violação.

### Verificador sobre a evidência E2E

Comando reproduzível (fixtures derivadas dos cenários de `sim_e2e_test`):

```sh
SUPERNOVA_ALLOWLIST='sim:alice,sim:bob' \
SUPERNOVA_INSTANCE_DAILY_USD=5 SUPERNOVA_RESERVE_ESTIMATE_USD=1 \
gleam run -m supernova/sim/check -- \
  test/fixtures/b2_e2e_data test/fixtures/b2_e2e_transcripts.jsonl
```

Saída:

```json
{"invariants":[{"invariant":"I1","ok":true,"violations":[]},{"invariant":"I2","ok":true,"violations":[]},{"invariant":"I3","ok":true,"violations":[]},{"invariant":"I4","ok":true,"violations":[]},{"invariant":"I5","ok":true,"violations":[]},{"invariant":"I6","ok":true,"violations":[]}]}
```

### Revisão CodeRabbit

Corrigido nesta rodada:

- `access.allowed_chats` aceita `sim:<id>`, com teste de configuração.
- O adaptador `sim` rejeita `chat_id`/`user_id` com `:` para não colidir com a codificação de principal; ids privados do `sim` continuam exigindo `allowed_chats`.
- O stream do `sim` espera até 60 s e publica um evento visível em falha ou timeout.
- O verificador usa o teto diário padrão de 5 USD, agrupa gasto no timezone configurado, só aceita auditorias `denied` para I4 e consome uma auditoria por negação.
- `core.json` malformado não é sobrescrito; o nascimento retorna falha e preserva o arquivo.
- Escritas parciais do nascimento são desfeitas; falha ao gravar a biografia do nome restaura o núcleo sem nome para permitir retry.
- O sorteio ignora candidatos de peso zero e `nth_result` avança a cauda da lista.
- O diretório temporário do teste do ledger inclui o pid da VM; o teste do nascimento usa o workspace isolado.

Riscos aceitos e documentados:

- A codificação de principal segue o PRD literalmente: `:` vira `_` e `_` permanece `_`. Por isso `sim:a_b` e `sim:a:b` colidem; o segundo é rejeitado no adaptador.
- O id de sessão é `canal:chat:user`; usuários com `:` não são representáveis sem mudar o contrato. O `sim` rejeita esses ids.
- O nascimento ainda roda no processo do router; um provedor lento bloqueia as outras conversas daquele handler. O turno normal já roda fora do router.
- No modo aberto, o workspace do router (`SUPERNOVA_WORKSPACE_ROOT`) e o root da política (`data_dir/workspace`) continuam divergentes; o PRD só fecha o layout no modo grupo fechado.
- I3 usa os registros `tool`/`role_tools` das transcrições; sucessos presentes só no audit log, sem papel declarado, não são reconstruídos pelo CLI.
- O CLI usa `SUPERNOVA_INSTANCE_DAILY_USD` e `SUPERNOVA_BUDGET_TIMEZONE`; sem eles assume 5 USD e `America/Sao_Paulo`, os padrões do app, mas não relê `supernova.yaml`.
