# PRD-D: relatório final

[PRD](../prd/PRD-D-discord.md) · PR #79 · 25/11

## Resumo

O Discord passou de "só envia" a canal completo do grupo fechado. Na prática,
ele não enviava nem recebia: o gateway era um esboço e o cliente REST nunca
chegava ao Discord. Agora:

| A pessoa | A agente |
|---|---|
| escreve no privado ou num canal de servidor autorizado | responde pelo grupo fechado, com streaming e "digitando" |
| digita um comando `/` | vê sugestões pelo papel dela; o comando aparece no canal e a resposta vem embaixo |
| clica num botão (seletor de modelo) | o Discord é respondido na hora, e a resposta edita a mensagem dos botões |
| manda imagem, voz, áudio, vídeo, documento ou figurinha | lê como no Telegram (PRD-A) |
| tem algo na agenda | recebe no privado, na mesma conversa em que escreve |

O `/health/ready` acompanha o gateway: pronto só depois do READY, fora na
queda e depois de 120 s sem ACK, e com o motivo legível quando o Discord
recusa (token ou intenção).

## Medição final

Não há bancada nesta PRD, nem bot real. O que foi medido é a suíte, contra um
gateway e uma API falsos locais (`test/discord_fake.gleam`) e as capturas
anonimizadas de fevereiro.

| | Master (`b3cc6fd`) | Esta PR |
|---|---|---|
| Testes | 2846 | **2914** |
| Cobertura de linha | 81,31% | **82,23%** |
| `discord_channel` | — | **88,95%** de 353 linhas |
| `discord_gateway` | — | **91,62%** de 346 linhas |

## Critérios da PRD (seção 8)

| Critério | Meta | Resultado |
|---|---|---|
| Gateway falso | READY marca pronto; queda tira e volta a marcar; 4014 deixa `failed` com o motivo | **Atingido** em `discord_gateway_live_test` (21 testes) e `discord_e2e_test`. |
| Ponta a ponta, falso | privado, servidor, menção, botão, comando `/`, imagem, voz | **Atingido** em `discord_e2e_test`, `discord_interactions_live_test`, `discord_slash_live_test`, `discord_media_live_test`; membro num servidor não autorizado fica sem resposta (`member_in_an_unauthorized_server_gets_no_reply_test`). |
| Interação | confirmação antes de 3 s com um turno longo | **Atingido**: confirmação em menos de 1 s com um turno de 2 s. |
| Autocompletar | sugestões pelo papel; nada para quem não tem acesso | **Atingido** em `discord_slash_live_test` e `commands_test`. |
| Identidade | mesmo agente depois de `/vincular` Telegram ↔ Discord | **Atingido** no gate (`runtime_test`), com o chat `dm:<pessoa>`, que agora é o formato real. |
| Cobertura | `discord_gateway` e `discord_channel` acima da média | **Atingido**: 91,62% e 88,95%, contra 82,23%. |
| Piloto (manual) | uma pessoa fala com a agente pelo Discord; o `/health/ready` cai sem token | **Não feito.** Roteiro em [`operations/DISCORD.md`](../operations/DISCORD.md). |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| D-01/D-02 | `198237a` | gateway de verdade (stratus), reconexão, prontidão, JSON por `gleam/json` |
| D-03 | `b6b769c` | interações respondidas; o REST passa a chegar ao Discord |
| D-04 | `2ee90cc` | comandos `/` registrados e autocompletar pelo papel |
| D-05 | `b2e9922` | mídia na entrada; corrida do Hello no gateway |
| D-06 | `7f6b510` | privado por pessoa, agenda, menções, `retry_after`, JSON válido |
| D-07 | `8a6e35d` | roteiro, gravador de fixtures, capturas de fevereiro nos testes |
| cobertura | `06b1fda` | caminho real (streaming, botões, erros, códigos de fechamento) |

## Defeitos achados

Além do que a PRD previa:

- **O REST nunca chegou ao Discord.** A URL inteira ia no campo de host, e a
  resposta de envio exigia `guild_id`, que a API não manda.
- **Texto cortado na primeira aspa.** O parse por busca em string fazia
  `ele disse "oi"` chegar como `ele disse \`.
- **Privado mudo.** As intenções não pediam `DirectMessages`.
- **Corrida no gateway.** O Hello podia chegar antes de o gateway saber da
  conexão, e o Identify se perdia. Achada por um teste intermitente.
- **Agenda em duas conversas.** O privado se chamava pelo canal de DM, e a
  agenda pela pessoa.
- **JSON inválido** com caracteres de controle além de `\n\r\t`.
- **O Slack tem o mesmo `set_host`.** Fica no PENDENCIAS, sem correção.

## Desvios declarados

Registrados na PRD:

- **D2:** só comandos globais. O Discord mostra duas vezes um comando
  registrado também no servidor.
- **6.2:** botão editado pela API do canal, e comando respondido com tipo 4.
  Sem token de interação e sem o limite de 15 minutos.
- **6.4:** mídia baixada fora do laço de eventos, e só para quem tem acesso.
- **6.5:** o privado passou a ser `dm:<id da pessoa>`.

## O que fica

- **Nada rodou contra o Discord real.** As capturas são de fevereiro. O
  gravador (`dev/discord/gravar.py`) está pronto para quando houver um bot.
- **`/voz` no Discord** precisa de um codificador Opus, junto com o do
  Telegram.
- **Ordem com anexos.** Um texto enviado logo depois de um vídeo grande pode
  chegar ao turno antes dele.
- **Código sem uso:** `discord_webhooks` e a maior parte de
  `discord_commands`.
