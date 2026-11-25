# PRDs C e I: relatório final

[PRD C](../prd/PRD-C-canais-whatsapp.md) · [PRD I](../prd/PRD-I-identidade.md) · PR #71 · 25/11

## Resumo

As duas PRDs rodaram juntas, como decidido em 24/11: de nada serve o WhatsApp
entrar se quem chega por ele não fala com a mesma agente do Telegram. Ficou
assim:

- **O núcleo não escolhe mais canal pelo nome (C-01).** Um roteador só, no
  lugar de cinco cópias, parametrizado por traits novas (`routes_inbound`,
  `supports_interactions`, `edits_interaction_source`, `turn_timeout_ms`,
  `private_chat_for`). Um teste de arquitetura impede que `supernova.gleam` e
  `channel_common_router` voltem a comparar nome de canal.
- **Webhook genérico (C-02).** `POST /webhook/<canal>`, assinado: 401 sem
  assinatura, 413 acima de 1 MB, e a mensagem entra no inbox antes do 200. A
  porta é própria e só abre quando um canal ligado recebe por webhook.
- **URL base dos canais (C-03).** https sempre; http só em loopback e nos
  hosts de `channels.internal_hosts`.
- **WhatsApp via GOWA v9.10 (C-04, C-06, I-04).** HMAC no webhook, basic auth
  e `X-Device-Id` no REST. Num grupo, a agente só responde a menção, a
  resposta a ela ou a comando; LID desconhecido num grupo recebe "Me chama no
  privado?". O LID aprendido vira apelido do telefone. Conta desconectada ou
  suspensa vira alerta aos admins e falha na saúde do canal. Compose com o
  GOWA fixado por digest, interface só no loopback, auto-update e resposta
  automática desligados, roteiro em `docs/operations/WHATSAPP.md`.
- **Mídia na entrada (C-05, C-05b).** Capacidade de mídia para todo canal:
  imagem até 5 MB, tipo conferido pelos bytes, arquivo temporário lido uma vez
  pelo modelo. O histórico guarda `[imagem]`.
- **Identidade entre canais (I-01 a I-03, I-05).** A primeira identidade da
  pessoa é a canônica; as ligadas depois são resolvidas no gate, antes do
  acesso, e em `agent_identity`. Pasta da agente, conversas, memória, acesso,
  orçamento e `/esquecer` seguem a pessoa, não o canal. `/vincular` gera no
  privado um código de 6 caracteres, válido por 10 min, de uso único, com até
  5 erros por hora; `/vincular CÓDIGO` no outro canal faz o vínculo e a pessoa
  é avisada no canal de origem. `/desvincular` desfaz.

## Medição final

Não há bancada nestas duas PRDs: nenhum critério é de vazão ou latência. O que
foi medido é a suíte.

| | Valor |
|---|---|
| Testes | **2769** |
| Cobertura de linha | **80,68%** |
| `gleam format --check`, `gleam build --warnings-as-errors` | ok |
| `docker compose config` (com e sem o perfil `whatsapp`) | ok |

A cobertura caiu de 80,39% para 80,37% na C-01, quando saíram ~300 linhas
duplicadas e cobertas (as cópias dos roteadores); a proporção caiu pela
remoção, não por código novo sem teste.

## Critérios da PRD C (seção 8)

| Critério | Meta | Resultado |
|---|---|---|
| Núcleo | nenhum `case` ou `==` sobre nome de canal fora de `channel/` e `adapters/` | **Atingido**, com teste de arquitetura no commit da C-01. |
| Webhook | sem assinatura válida, 401; com, a mensagem chega ao inbox antes do 200 | **Atingido** em `test/channel/webhook_server_test.gleam`, que também cobre o 413 e a porta ocupada. |
| WhatsApp falso | privado, grupo com menção, resposta citada, imagem, `is_from_me` ignorado, conta caída gera alerta | **Atingido** em `test/adapters/whatsapp_channel_test.gleam`, `whatsapp_adapter_test.gleam` e `whatsapp_inbound_test.gleam`, com payloads da versão fixada do GOWA. |
| Piloto (manual, pelo mantenedor) | a Belle, membro pelo WhatsApp, ganha a agente dela: nasce na primeira mensagem e recebe o nome que ela der | **Não feito.** Nada rodou contra um GOWA real nem contra o WhatsApp. |

## Critérios da PRD I (seção 8)

| Critério | Meta | Resultado |
|---|---|---|
| Depois de `/vincular` | a mesma pasta de agente, o mesmo núcleo, a mesma memória nos dois canais | **Atingido** em `test/core/identity/linking_test.gleam` e `test/e2e/cross_channel_e2e_test.gleam`. |
| `buscar_conversa` / `lembrar` | acham, num canal, o que foi dito no outro | **Atingido** em `test/e2e/cross_channel_e2e_test.gleam`. |
| `/esquecer` num canal | apaga as conversas e memórias de todos os canais da pessoa | **Atingido** no mesmo arquivo. |
| Código | expira em 10 min, um uso, 5 erros por hora | **Atingido**, com relógio de teste. |
| Identidade nova sem código | continua sendo uma pessoa à parte (sem acesso, se não estiver na lista) | **Atingido** em `test/core/identity/aliases_test.gleam`. |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| C-01 | `7338800` | o núcleo não escolhe canal pelo nome; traits e teste de arquitetura |
| C-02 | `a0813fd`, `9746ef4` | servidor de webhook genérico; porta ocupada é erro, não queda |
| C-03 | `a8df197` | checagem compartilhada da URL base dos canais |
| C-04, I-04 | `625e188` | WhatsApp via GOWA, entrada e saída |
| C-05 | `31e9f5e` | capacidade de mídia na entrada; imagens do WhatsApp |
| C-05b | `5e27e79` | a imagem que a pessoa manda chega ao modelo |
| C-06, I-06 | `128d7d1` | compose do GOWA, roteiro de pareamento, documentação |
| I-01 | `186625f` | apelidos: a mesma pessoa em vários canais |
| I-02 | `0454bfa` | `/vincular` e `/desvincular` |
| I-03 | `078e56c` | esquecer alcança todos os canais da pessoa |
| I-05 | `3ba0dab` | o que foi dito num canal é achado no outro |
| fora da PRD | `772fb8d`, `3627a46`, `500e2a7` | grupos desligados por padrão; servidor MCP morto não derruba o dono da porta; teste espera o processo morto |

## Corridas resolvidas

- **Porta ocupada no webhook.** O `mist` liga o listener ao processo que
  chama, então um bind recusado derrubava o chamador: no boot, derrubaria a
  Supernova; na suíte, derrubava o eunit no meio. Agora é erro de canal.
- **Servidor MCP morto matando o dono da porta.** Um `epipe` de um servidor
  que já tinha morrido derrubava o processo dono da porta, e a suíte caía com
  ele. Era corrida antiga, achada no caminho.
- **`timeout_kills_the_process_test` conferindo antes da hora.** O teste lia a
  morte do processo sem esperar por ela. O commit da C-06 foi feito sem a
  leitura da rodada em que ele falhou; a correção veio no `500e2a7`, com a
  suíte inteira verde.

## O que fica

- **Entrega da agenda (D5).** A tarefa é entregue no privado do canal canônico
  da pessoa, não no canal em que foi marcada. Isso nunca entrega num canal
  desvinculado. Entregar no canal de origem exige levar a identidade de origem
  no contexto do turno; é decisão do mantenedor.
- **GOWA serve a mídia em `/statics` sem autenticação**, mesmo com basic auth
  ligado. A porta dele não pode ser publicada fora do loopback, e o compose já
  a prende lá.
- **Desvio declarado da PRD C.** A checagem da URL base (C-03) não usa a
  resolução de nome da PRD-E: estas URLs vêm do operador e são internas de
  propósito, e o que se protege ali é o segredo em trânsito, não SSRF.
- **`WHATSAPP_AUTO_DOWNLOAD_MEDIA`** foi inferido da chave de configuração do
  GOWA, não lido no código dele. O padrão já é ligado.
- **Nada rodou contra o WhatsApp real.** O pareamento e a primeira conversa
  são manuais, pelo roteiro.
