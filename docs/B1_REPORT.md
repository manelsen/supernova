# PRD B1 — Relatório de Execução

## Linha de base e estado final

| Métrica | Início | Final |
|---|---|---|
| `gleam test` | 2007 passaram, 0 falhas | 2158 passaram, 0 falhas |
| Cobertura de linhas | 74,56% (gate 73) | 75,67% (10208/13491, gate 75) |
| `gleam build --warnings-as-errors` | verde | verde |
| `gleam format --check src test` | verde | verde |

Ambiente: Gleam 1.19.2 / Erlang 28.5.0.8, Linux x64.

## Caminho de uma mensagem

```text
canal (Telegram/Discord)
  → principal (channel:user_id)
  → acesso (allowlist/admin/member, chat autorizado, rate limit)
  → comandos (/eu, /uso, /acesso, /teto, /auditoria) [sem LLM]
  → orçamento por principal + teto global diário
  → LLM
  → SyscallGateway: capability → workspace → orçamento de ferramenta
                    → execução → ledger → audit log
  → ledger (tokens, ferramenta, custo) + audit log + alertas
  → resposta do canal (chunking 4096/2000)
```

Componentes:

- `core/principal.gleam`: identidade separada da sessão.
- `core/access/{types,pure,actor}.gleam`: decisão pura, listas persistentes em
  `<data_dir>/access.json`, avisos de negação de 24 h.
- `core/closed_group/{types,pure,runtime,global}.gleam`: gate único antes do
  LLM, comandos, orçamento/teto, contexto do executor, alertas e auditoria.
- `core/budget_policy/`: janela por hora (`tokens_per_hour`,
  `tool_calls_per_hour`) e fail-closed.
- `core/resource_ledger/`: trilha por principal em
  `<data_dir>/ledger/YYYY-MM-DD.jsonl`, rotação de 30 dias.
- `core/syscall/actor.gleam`: `invoke_tool/5` com pipeline do kernel.
- `core/tool_dispatch.gleam`: única module que importa `supernova/tools/*`.
- `core/alerts/{group_pure,group_actor}.gleam`: deduplicação de alertas.
- `core/instance_budget/`: teto diário ajustável por `/teto liberar`.
- `config_check.gleam` + `check_config_main.gleam`: validação no boot e CLI.
- Audit log: `<data_dir>/audit_log/<agent>/.supernova/audit.log`, texto com
  `timestamp agent operation target result details`; rotação ao passar de
  10 MB, mantendo cinco backups (`audit.log.1` … `.5`).

## Padrões de segurança

| Item | Padrão |
|---|---|
| Acesso | `allowlist`, listas vazias; ninguém usa até configurar |
| Chats/grupos | lista vazia; só conversas privadas de principals autorizados |
| Capabilities `member` | `web`, `web_fetch`, `file_system`, `canvas`, `github`; nega `safe_shell`, `process`, `browser`, `gateway` |
| Capabilities `admin` | `*` |
| Orçamento `member` | 50.000 tokens/h, 60 ferramentas/h |
| Orçamento `admin` | ilimitado (`-1`) |
| Rate limit `member` | 10 mensagens/minuto |
| Rate limit `admin` | ilimitado (`-1`) |
| Teto global | US$ 5,00/dia, `America/Sao_Paulo` |
| Falha de access/budget/ledger | nega (fail-closed), mensagem interna genérica |
| Audit log | sem conteúdo de mensagem do usuário |

## Decisões sem especificação explícita

- O runtime de grupo fechado é publicado em `persistent_term` e reconstruído a
  partir dos handles supervisionados; um ator reiniciado é reutilizado sem
  reiniciar o processo inteiro.
- O gate retorna `Ignored` (sem resposta) para grupos não autorizados, exceto
  `/eu`; administradores podem autorizar o chat corrente com `/acesso chat
  adicionar`.
- O limite de mensagens usa janela deslizante de 60 s; comandos e `/eu` não
  contam.
- Em servidores Discord, a autorização usa o `guild_id` (`discord:guild:<id>`);
  o id do canal viaja anotado como `<canal>@guild:<guild>` e é removido antes
  de chamar a API. Alertas abrem DM via `/users/@me/channels`.
- Se o ator de acesso estiver indisponível, os alertas usam a lista de admins
  da configuração como fallback para não silenciar falhas.
- Prova do teste de isolamento: um `import supernova/core/blackboard` temporário
  em `src/supernova.gleam` fez `test/architecture/isolation_test` falhar;
  removido o import, o teste voltou a passar.
- O teto diário considera o dia no fuso configurado; o arquivo do ledger usa
  dias UTC, e a soma diária é filtrada pelo timestamp no fuso.
- O custo de uma chamada é estimado com `pricing` e registrado no ledger; a
  estimativa de tokens usa `usage` quando disponível no provider e, caso
  contrário, caracteres/4.
- Alertas são deduplicados por tipo+sujeito por uma hora; o envio usa o
  principal do admin como destino DM.
- A saída para canais suportados usa os limites existentes de chunking
  (Telegram 4096, Discord 2000).

## Cobertura

`make coverage` mediu **75,67%** (10208/13491 linhas). O alvo de 78% não foi
alcançado sem testes artificiais: os maiores buracos restantes são módulos de
canais/rede (`channel/registry` 249 linhas, `discord_commands` 169,
`telegram` 159, `discord_webhooks` 105, `whatsapp_adapter` 92) e o bootstrap
(`supernova` 134), que exigem harness HTTP/Chromium ou sobem o processo inteiro.
O threshold foi fixado no maior valor honesto arredondado para baixo, **75**,
acima da linha de base de 74,56%.

## Branch, commits e CI

- Branch: `feat/grupo-fechado`
- Commits: série temática (`ci`, `git_inspect`, `config`, `ledger`, `gateway`,
  `access`, `isolation`, `docs` e as correções de fechamento).
- PR: https://github.com/manelsen/supernova/pull/12
- CI: quality gates rodados localmente; o run do PR está em
  `gh pr checks 12`.

## Observações

- `blackboard` e `memory_federation` continuam desligados; há testes de
  arquitetura em `test/architecture/isolation_test.gleam`.
- Os testes de ponta a ponta de Telegram e Discord usam o registry real com
  HTTP mock/hooks determinísticos, sem rede.

## Correções pós-revisão (18/11)

A revisão do PR encontrou problemas de concorrência e de autorização. Todos
têm teste que falhava antes da correção.

| Problema | Efeito | Correção |
|---|---|---|
| Turnos com barreira rodavam dentro do ator do router | Cada turno de LLM bloqueava o router de todos; acima de 30 s, o processo chamador caía | O turno sempre roda num processo próprio; o router responde na hora com o indicador de digitação |
| O laço de polling consumia o stream do turno | Um turno lento travava todos os outros chats do canal | Fila por chat (`supernova_chat_lanes_ffi`): chats diferentes em paralelo, o mesmo chat em ordem |
| O gateway executava a ferramenta dentro do ator | Fila global de ferramentas; ferramenta acima de 2 s era dada como recusada mas continuava executando | O gateway só autoriza (e já desconta o orçamento); a ferramenta roda no processo do turno; o resultado vai ao audit log por mensagem |
| Papel `"membro"` no contexto, manifestos com chave `"member"` | Membros não conseguiam usar nenhuma ferramenta | `role_key` estável (`admin`/`member`) para contexto e manifestos; `role_name` só para exibição |
| Cliques em botões não passavam pela barreira | Não membro podia trocar provider/modelo de uma sessão compartilhada | Interações passam pela mesma barreira das mensagens |
| Recusa do kernel no caminho assíncrono virava `StreamFailure` | O usuário ficava vendo "Thinking..." sem explicação | A recusa chega como mensagem final |
| Mensagem final do stream não era dividida | Edição acima de 4096 (Telegram) ou 2000 (Discord) caracteres era rejeitada | A primeira parte edita o placeholder; as demais vão como mensagens novas |
| Teto diário copiava o histórico inteiro do ledger a cada chamada ao LLM | Ficava mais lento com o tempo e podia falhar fechado sem motivo | A soma do dia é feita dentro do ator do ledger |
| `handle_message` público rodava sem kernel | Caminho sem orçamento nem gateway, sem chamadores | Removido; o contexto vazio do executor passou a ser `member` |

Estado após as correções: `gleam test` 2167 passaram, 0 falhas; cobertura
75,75% (gate 75); `gleam build --warnings-as-errors` e `gleam format --check`
verdes.
