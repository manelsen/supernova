# PRD B1 — Relatório de Execução

## Linha de base e estado final

| Métrica | Início | Final |
|---|---|---|
| `gleam test` | 2007 passaram, 0 falhas | 2135 passaram, 0 falhas |
| Cobertura de linhas | 74,56% (gate 73) | 75,07% (10093/13444, gate 75) |
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

`make coverage` mediu **75,07%** (10093/13444 linhas). O alvo de 78% não foi
alcançado sem testes artificiais: os maiores buracos restantes são módulos de
canais/rede (`channel/registry` 249 linhas, `discord_commands` 169,
`telegram` 159, `discord_webhooks` 105, `whatsapp_adapter` 92) e o bootstrap
(`supernova` 134), que exigem harness HTTP/Chromium ou sobem o processo inteiro.
O threshold foi fixado no maior valor honesto arredondado para baixo, **75**,
acima da linha de base de 74,56%.

## Branch, commits e CI

- Branch: `feat/grupo-fechado`
- Commits: ver `git log --oneline master..feat/grupo-fechado`
- PR: não criado nesta execução (o mantenedor fará a revisão).
- CI: não executado localmente; os quality gates foram rodados no worktree.

## Observações

- `blackboard` e `memory_federation` continuam desligados; há testes de
  arquitetura em `test/architecture/isolation_test.gleam`.
- Os testes de ponta a ponta de Telegram e Discord usam o registry real com
  HTTP mock/hooks determinísticos, sem rede.
