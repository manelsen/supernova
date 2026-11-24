[PRD]
# PRD E: endurecimento pós-auditoria

> **Situação em 24/11/2026:** aprovada pelo mantenedor; D1 a D3 seguem as
> recomendações (seção 5).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio.

## 1. Contexto

Três auditorias externas (canais, kernel; LLM, tools e self) leram o código
em `d2cf654`. Os achados abaixo foram conferidos no master `252e1a4` e
pesam no piloto (Telegram, DeepSeek, membros). Os que não pesam hoje
(provider Anthropic, Discord, MCP, código morto) ficam para as PRDs C e S e
para a limpeza.

| # | Achado | Onde (252e1a4) |
|---|---|---|
| A1 | A mensagem recusada pela fila do chat (cheia) é marcada como feita no inbox: some sem resposta e sem retomada | `channel/channel_kit.gleam:218-221` |
| A2 | A proteção de URL só compara o texto do host (`10.`, `169.254.`, `localhost`…): um domínio que resolve para a rede interna passa. Membros têm `web_fetch`, e a rede do Docker tem o computador, o Grafana e o Prometheus | `core/url_guard.gleam:10-127`, `tools/web.gleam:14-33` |
| A3 | Nenhum teto no resultado de uma tool nem no corpo baixado pelo `web_fetch`: um arquivo ou página grande vai inteiro ao modelo (custo, contexto) | `core/executor.gleam` (sem truncamento), `tools/web.gleam:19-23` |
| A4 | Sem política de orçamento, o gateway autoriza (`None -> Ok(Nil)`) | `core/syscall/actor.gleam:260` |
| A5 | Sem contexto de grupo fechado, o executor roda com a lista crua de tools, sem gateway | `adapters/channel_common_router.gleam:382` |
| A6 | A tool `gateway` responde sucesso a `ReadFile`/`WriteFile` sem tocar o disco (só admins a têm; mente ao modelo) | `core/syscall/actor.gleam:358-385`, `core/tool_dispatch.gleam:37` |
| A7 | O README diz "Discord: Supported"; o Discord não recebe mensagens (o gateway é um stub) | `README.md:16, 64`, `adapters/discord_gateway.gleam:553-560` |

Observações da conferência: o `web_fetch` **não** segue redirects (o
comentário do módulo diz que sim; está errado), então o vetor de redirect
da auditoria não existe hoje. A política de workspace sem política só
autoriza quando não há manifest de capacidades (desenvolvimento); em
produção, nega.

## 2. Objetivo

Nenhuma mensagem perdida por fila cheia; nenhuma tool de membro alcançando a
rede interna; nenhuma saída de tool sem teto; o gateway e o executor
negando quando falta a política; o README dizendo o que roda.

## 3. Fora de escopo

- Código morto (decisão do mantenedor módulo a módulo, à parte).
- Provider Anthropic, Discord, MCP (PRDs C e S).
- `safe_shell`, `process`, `browser`, `git_inspect` sob a WorkspacePolicy:
  são negados a membros; ficam para depois.
- Durabilidade da auditoria e do ledger (fsync): médio, à parte.

## 4. Quality gates

Os de sempre (`AGENTS.md`): `gleam format --check src test`,
`gleam build --warnings-as-errors`, `make coverage` (testes ok, cobertura
nunca abaixo do início da história), `git status --short` limpo. TDD; sem
rede nos testes; sem `sleep` fixo.

## 5. Decisões do mantenedor

- **D1. Mensagem recusada pela fila cheia.**
  - (a) Fica pendente e é ressubmetida com espera crescente (1 s, 2 s, 4 s…,
    até 2 min); se ainda não couber, a pessoa recebe "estou com muitas
    mensagens; já respondo" e a mensagem segue pendente.
  - (b) Fica pendente só até o próximo boot (o que a auditoria propõe).
  - **Recomendação: (a).** (b) deixa a pessoa sem resposta até alguém
    reiniciar.
- **D2. Teto da saída de tool.** Recomendação: 20.000 caracteres, com
  "[saída cortada: N caracteres; peça um trecho menor]" no fim; o corpo do
  `web_fetch` lido até 2 MB.
- **D3. Tempo-limite por tool.** Recomendação: 60 s por padrão, 300 s para o
  `computador`; configurável em `tools.timeouts`.

## 6. Histórias

### E-01: Fila cheia não perde mensagem (A1, D1)
`Rejected` não chama `finish`. Implementa D1. Testes: fila cheia → a
mensagem continua pendente no inbox e é atendida quando a fila esvazia; o
aviso à pessoa sai uma vez só.

### E-02: Proteção de URL que resolve o nome (A2)
`url_guard` resolve o host (`inet:getaddrs`, A e AAAA) e nega se **qualquer**
endereço for loopback, privado (10/8, 172.16/12, 192.168/16), CGNAT
(100.64/10), link-local (169.254/16, fe80::/10), ULA (fc00::/7), 0/8,
multicast, IPv4 mapeado em IPv6, ou o nome de um serviço do compose. Formas
decimal, octal e hex normalizadas por `inet:parse_address`. O `web_fetch`
continua sem seguir redirects (o comentário do módulo é corrigido).
Risco residual: entre a checagem e a conexão, o DNS pode mudar (rebinding);
fica documentado, e a mitigação de rede é a seção 8. Testes com resolvedor
falso.

### E-03: Teto e tempo-limite das tools (A3, D2, D3)
O executor corta todo resultado de tool em D2 e roda cada tool com o
tempo-limite de D3 (processo à parte, morto no fim do tempo, como
`memory/decision.within`). O `web_fetch` lê no máximo 2 MB. Testes:
resultado grande cortado com o aviso; tool lenta vira erro de tempo-limite
para o modelo, e o turno segue.

### E-04: Gateway e executor negam sem política (A4, A5)
Budget ausente com manifest de capacidades presente → `Error("budget policy
unavailable")`, como já faz a workspace. O ramo `_, _` do executor: com o
grupo fechado imposto (`closed_group_global.is_enforced()`), nega o turno;
sem ele (desenvolvimento), segue como hoje. Teste de arquitetura que falha
se um novo `start` do gateway em produção passar `None`.

### E-05: Sai a tool `gateway` (A6)
Sai de `tool_dispatch.builtin_tools` e das listas de capacidades. Os
`SyscallOp` que fabricam sucesso (`run_op`) passam a devolver
`SyscallError("não implementado")` até alguma PRD precisar deles.

### E-06: README e arquitetura dizem a verdade (A7)
Tabela de canais: Telegram (entrada e saída), sim (harness), Discord e os
demais (só saída; entrada pendente). Corrige "Discord: Supported" e a
"streaming" onde for uma chamada única. `ARCHITECTURE.md` e
`COMPONENTS.md` acompanham.

## 7. Critérios de aceite

| Critério | Meta |
|---|---|
| Fila cheia | nenhuma mensagem marcada feita sem turno |
| `web_fetch` para `http://grafana:3000`, `http://10.0.0.1`, um nome que resolve para 127.0.0.1 | negado |
| Saída de tool | ≤ teto D2 em todo caminho |
| Gateway sem budget em produção | nega |
| README | nenhum canal "Supported" sem entrada |

## 8. Riscos

- **DNS rebinding.** A checagem de E-02 tem janela entre resolver e
  conectar. A mitigação definitiva é de rede: o contêiner da Supernova numa
  rede Docker que não alcança o Grafana, o Prometheus nem o computador
  além das portas que ela usa. Fica como recomendação de operação.
- **Turnos longos legítimos** podem bater no tempo-limite de D3; o
  `computador` tem o seu.
