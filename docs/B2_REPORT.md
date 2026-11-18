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
| Testes | 2226 | 2264 |
| Cobertura de linhas | 68,19% | 75,84% (11167/14724) |

A cobertura "antes" foi medida no tree de trabalho durante a implementação, não no commit base; o número fica registrado como limitação. O gate do repositório é 75%.

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
