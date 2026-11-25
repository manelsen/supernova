[PRD]
# PRD D: Discord com paridade do Telegram

> **Situação em 25/11/2026:** aprovada pelo mantenedor; D1 a D6 decididas
> (seção 5). Na D6, o mantenedor pediu autocompletar no lugar do texto livre.
> Item 1 do roadmap ([PENDENCIAS](../PENDENCIAS.md), seção 0). Depende só do
> que já está no master: a tabela de canais e os traits (PRD-C), a identidade
> entre canais (PRD-I) e a mídia (PRD-A).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio. Se a sessão for interrompida, retome pela
> primeira história sem commit, conferindo `git log --oneline` contra os
> títulos de commit.

## 1. Contexto

### 1.1 O que existe

O adaptador do Discord tem sete módulos em `src/supernova/adapters/`, cerca de
9.900 linhas, e 398 testes. O caminho de saída funciona: o
`discord_channel` envia, edita, mostra "digitando", faz streaming por edição e
monta botões e menus. O pipeline do grupo fechado é o mesmo do Telegram:
`discord_channel` entrega um `ChannelInbound` ao `channel_kit`, e dali em
diante nada é do Discord. Os traits (`channel/traits/discord.gleam`) já
declaram principais (`discord:<user_id>`), chats privados (`dm:…`) e grupos
autorizados por guild (`discord:guild:<id>`).

### 1.2 O que falta

- **O Discord não recebe nada.** O gateway é um esboço:
  - `connect_to_gateway` e `resume_gateway` só mudam o status
    (`discord_gateway.gleam`, "In production, this would start the actual
    stratus actor");
  - `send_identify` e `send_heartbeat` montam o payload e o descartam;
  - nenhum evento chega ao `discord_channel`.

  O `stratus` 3.0.0, cliente WebSocket, já está no `manifest.toml` e não é
  usado. Os testes do gateway cobrem só o parse e o encode.
- **O gateway lê JSON com busca em string.** `parse_gateway_message`,
  `json_decode_int_field` e `do_extract_balanced` procuram campos no texto. O
  `identify_payload` concatena o token dentro do JSON sem escape.
- **Interações sem resposta ao Discord.** O Discord exige que toda interação
  (botão, menu, comando `/`) seja respondida em `POST
  /interactions/{id}/{token}/callback` em até 3 segundos. Sem isso, a pessoa
  vê "Esta interação falhou", mesmo que a resposta chegue depois como
  mensagem nova.
  - O `discord_commands` sabe montar essas respostas (`deferred_response`,
    `encode_response`), mas nenhum módulo fora dele o importa.
- **Os comandos `/` nunca são registrados.** O Telegram publica o menu no boot
  a partir de `core/closed_group/commands` (#51). O Discord tem
  `register_global_command` e `register_guild_command`, que ninguém chama.
- **Anexos ignorados.** O `discord_message_to_port` copia só o texto.
  Imagem, áudio, mensagem de voz, vídeo, documento e figurinha se perdem. No
  Telegram e no WhatsApp eles passam pelo `inbound_media` e pela leitura de
  mídia (PRD-A).
- **Sem prontidão.** O Telegram informa a saúde do canal a cada poll
  (`channel/health`). O Discord só informa que subiu, e um gateway que cai
  continuaria aparecendo como pronto no `/health/ready`.
- **A agenda não chega ao privado.** O trait diz `private_delivery: False`,
  embora `private_chat_for` (`open-dm:<user_id>`) e `discord_rest.open_dm`
  já existam.
- **O REST nunca chegou ao Discord** (achado na execução, D-03). A URL
  inteira ia no campo de host da requisição (`request.set_host`), e toda
  chamada terminava em `ConnectTimeout`. A resposta do envio também exigia
  `guild_id`, que a API não manda. O "só envia" do `STATUS.md` era, na
  prática, "nem envia". O mesmo `set_host` está em `slack_adapter.gleam`,
  fora desta PRD (anotado no PENDENCIAS 3.2).
- **Defeitos conhecidos** (PENDENCIAS 3.2):
  - um `retry_after` inteiro é lido como milissegundos: o Discord manda
    segundos, então `5` vira 5 ms em vez de 5 s (`extract_retry_after`, em
    `discord_rest.gleam`). O valor com fração (`0.35`) já é convertido certo.
    A PENDENCIAS 3.2 descrevia isso como truncamento;
  - o `discord_webhooks`, que recebe interações por HTTP, também não é usado
    por nenhum outro módulo. Ele é o caminho alternativo ao gateway e fica
    fora desta PRD (seção 3).

### 1.3 Por que agora

A paridade com o Telegram foi decidida em 22/11 e é o item mais antigo parado
no roadmap. Enquanto o WhatsApp espera um chip, o Discord é o segundo canal em
que o grupo fechado pode ser usado de verdade.

## 2. Objetivo

Uma pessoa membro do grupo fechado conversa com a sua agente pelo Discord, no
privado e num canal de servidor autorizado, com o mesmo comportamento do
Telegram:

- texto, comandos, botões e mídia;
- agenda no privado;
- `/vincular` entre o Discord e os outros canais;
- prontidão real no `/health/ready`.

## 3. Fora de escopo

- **Interações por HTTP** (`discord_webhooks`, Interactions Endpoint URL). O
  gateway já entrega as interações; o endpoint HTTP exige URL pública e fica
  para quando houver motivo.
- **Voz no Discord** (canais de voz e `/voz` com mensagem de voz). Ver D4.
- **Sharding.** Um bot abaixo de 2.500 servidores usa um shard só.
- **Compressão do gateway** (`zlib-stream`). JSON sem compressão basta para o
  volume do piloto.
- **Slack, Matrix e os demais canais.** Esperam o Discord.
- **Apagar o código sem uso** do `discord_webhooks` e da parte do
  `discord_commands` que esta PRD não usar. Fica para a limpeza de código
  morto (PENDENCIAS 0.3), depois que esta PRD mostrar o que é usado.

## 4. Quality gates

Os de sempre (`AGENTS.md`): `gleam format --check src test`,
`gleam build --warnings-as-errors`, `make coverage` sem cair.

**Testes sem rede.** O Discord nos testes é um servidor falso, nunca o real:

- um gateway WebSocket falso (mist);
- uma API REST falsa, como o `test/telegram_fake.gleam`.

Os payloads vêm de fixtures gravadas da API real e anonimizadas, como as
atuais de `test/fixtures/discord/` (gravadas em 27/02/2026). As que faltarem
(D1) são gravadas por um script em `dev/discord/`, como o
`dev/gemini/gravar.py`, e anonimizadas antes do commit.

## 5. Decisões do mantenedor

- **D1. Aplicação e servidor de teste.** O gateway exige um bot de verdade,
  com a intenção privilegiada `MESSAGE_CONTENT` ligada no Developer Portal.
  Sem ela, o Discord fecha a conexão com o código 4014, e as mensagens de
  servidor chegam sem texto.
  - Gravar as fixtures que faltam pede o token desse bot e um servidor de
    teste: mensagem de voz, anexo, figurinha, interação de botão, interação
    de comando `/`, `RESUMED`, `INVALID_SESSION`.
  - **Decidido:** seguir com as fixtures de fevereiro. Payloads que elas não
    têm são montados a partir da documentação e marcados como tal no teste.
    A gravação nova fica para quando houver o bot (D-07 só documenta o
    script).
  - Recomendação original: você cria a aplicação e um servidor de teste só seu e
    põe o token no `.env` (`SUPERNOVA_DISCORD_TOKEN`), sem passar pelo chat.
    O executor grava e anonimiza. Se não houver token, as histórias seguem
    com as fixtures de fevereiro e com payloads montados a partir da
    documentação, marcados como tal no teste. As fixtures gravadas os
    substituem depois.
- **D2. Onde registrar os comandos `/`.**
  - (a) No servidor de `discord.guild_id`: aparecem na hora, só lá.
  - (b) Globais: valem para o privado e todos os servidores.
  - **Desvio na execução (D-04):** só globais. O Discord mostra duas vezes um
    comando registrado com o mesmo nome no global e no servidor, e a lista
    seria a mesma. No servidor de `discord.guild_id` vai uma lista vazia,
    que limpa cópias antigas. Os globais valem no privado e em todos os
    servidores.
  - **Decidido:** os dois, porque o privado só vê comandos globais.
    Globais com a lista de membro. No servidor configurado, a mesma lista.
    O menu de admin não existe no Discord: a permissão de comando por
    pessoa exige OAuth do dono do servidor. O admin digita o comando, e o
    gate decide, como hoje.
- **D3. Servidores e canais.** Hoje um servidor inteiro é autorizado como
  `discord:guild:<id>`, e cada canal ou thread dele vira um chat próprio.
  - **Decidido:** manter. A thread conta como chat próprio, autorizada
    pelo servidor. No servidor, a agente vê o que o grupo fechado já define:
    as mensagens da sua pessoa e as que a mencionam.
  - **Não seguir o WhatsApp** (`allow_groups: false`): lá a decisão foi por
    causa do número pessoal; no Discord, o servidor é o grupo.
- **D4. `/voz` no Discord.** O Discord aceita mensagem de voz de bot: um
  anexo OGG/Opus com `flags: 8192`, `duration_secs` e `waveform`. A TTS da
  PRD-A gera WAV, e converter pede um codificador Opus na imagem (ffmpeg ou
  `opusenc`).
  - **Decidido:** fora desta PRD. `sends_voice` continua `False`: o
    `/voz` grava a preferência, e a resposta segue em texto, como no Telegram
    hoje. Volta
    junto com o `/voz` do Telegram (`sendVoice`, PENDENCIAS 0.3), que pede o
    mesmo codificador.
- **D5. Resposta a botões e menus.**
  - (a) Confirmar a interação sem mudar nada e mandar a resposta como
    mensagem nova, como os traits dizem hoje (`edits_interaction_source:
    False`).
  - (b) Editar a mensagem que tinha os botões, como o Telegram
    (`edits_interaction_source: True`).
  - **Decidido:** (b). O seletor de modelo e a agenda ficam iguais nos
    dois canais, e a conversa não acumula menus velhos. Para isso, a
    confirmação é o tipo 6 (`DEFERRED_UPDATE_MESSAGE`), e a resposta edita a
    mensagem original pelo token da interação, que vale 15 minutos.
- **D6. Comandos `/` com argumento.** O `/model <provedor> <modelo>` e o
  `/acesso` têm argumentos.
  - **Decidido: autocompletar.** Cada comando que aceita argumento é
    registrado com uma opção opcional `args`, de texto, com
    `autocomplete: true`. Enquanto a pessoa digita, o Discord manda uma
    interação de autocompletar (tipo 4) e espera até 25 sugestões em 3 s
    (resposta tipo 8). Ao enviar, a interação vira texto
    (`discord_slash_command_text`), e o núcleo trata como no Telegram. As
    sugestões vêm do núcleo, não do adaptador (6.3).

## 6. Desenho

### 6.1 Gateway

O `discord_gateway` passa a ter uma conexão de verdade, num processo próprio
supervisionado pelo ator do gateway:

```
boot ─► GET /gateway/bot (URL, limite de identify)
     ─► stratus: wss://…/?v=10&encoding=json
          ◄─ op 10 Hello (heartbeat_interval)
          ─► op 1 Heartbeat, com jitter no primeiro, depois a cada intervalo
          ─► op 2 Identify (token, intents)
          ◄─ op 0 READY (session_id, resume_gateway_url) ─► canal pronto
          ◄─ op 0 MESSAGE_CREATE / INTERACTION_CREATE ─► discord_channel
          ◄─ op 11 Heartbeat ACK
```

- **JSON com `gleam/json`.** O parse e o encode por string saem. O token entra
  no payload pelo encoder, com escape.
- **Reconexão:**

  | Situação | O que o gateway faz |
  |---|---|
  | Heartbeat sem ACK | Fecha e retoma |
  | op 7 Reconnect | Retoma em `resume_gateway_url` com op 6 Resume e a última sequência |
  | op 9 com `d: true` | Retoma |
  | op 9 com `d: false` | Espera de 1 a 5 s e faz Identify novo |
  | Queda de rede | Retoma com backoff exponencial (1 s a 60 s) |

- **Códigos de fechamento que não reconectam:**
  - 4004: token inválido;
  - 4010 a 4013: shard ou intents inválidos;
  - 4014: intenção não autorizada no Portal.

  Esses viram `failed` no `channel/health` com o motivo legível. Para o
  4014, o motivo é "ligue a Message Content Intent no Developer Portal". O
  alerta de canal sem conexão, já existente no Grafana, dispara.
- **Prontidão.** O canal está pronto entre READY ou RESUMED e a próxima queda.
  O estado vai para o `channel/health` a cada mudança e a cada ACK, como o
  Telegram a cada poll.
- **Identify.** Respeitar `session_start_limit` do `/gateway/bot`: sem
  identify restante, esperar `reset_after` em vez de insistir.

### 6.2 Interações

```
INTERACTION_CREATE ─► confirmar em até 3 s (callback):
    botão ou menu   ─► tipo 6 (deferred update)   ─► a resposta edita a mensagem dos botões (D5)
    comando /       ─► tipo 4, ecoando o comando  ─► a resposta vai como mensagem normal
    autocompletar   ─► tipo 8, com as sugestões (6.3)
                    ─► ChannelInbound ao channel_kit, como hoje
```

**Desvio da primeira versão, na execução (D-03).** A primeira versão usava o
token da interação: tipo 5 e follow-up para comandos, edição de `@original`
para botões. Ficou mais simples e sem prazo:

- a mensagem com os botões é do próprio bot, então a edição vai pela API do
  canal (`PATCH /channels/{canal}/messages/{id}`), com o id que vem em
  `message.id` da interação. Não há limite de 15 minutos;
- o comando `/` é respondido com tipo 4, mostrando o comando no canal, como
  o Telegram mostra o comando digitado. A resposta da agente segue pelo
  caminho normal, com streaming, sem token para guardar.

O resto desta seção descreve a primeira versão e fica como registro.

- **A confirmação sai antes do turno**, no processo do `discord_channel`, sem
  esperar a fila do chat. Se falhar, o log registra e o turno segue: a
  resposta ainda pode chegar como mensagem nova.
- **A resposta usa o token da interação**, válido por 15 minutos:
  - `PATCH /webhooks/{app_id}/{token}/messages/@original` para editar;
  - `POST /webhooks/{app_id}/{token}` para follow-up.

  Passados os 15 minutos (um turno longo), cai para mensagem nova no canal.
- **O que se aproveita do `discord_commands`:** os tipos de resposta e o
  encode, trocados para `gleam/json`. O cliente de comandos dele (ator,
  handlers) não entra.

### 6.3 Comandos `/`

- **No boot**, depois do READY:
  - `PUT /applications/{app_id}/commands` com a lista global;
  - e, se houver `discord.guild_id`, `PUT
    /applications/{app_id}/guilds/{guild_id}/commands`.

  As duas listas vêm de `core/closed_group/commands`, a mesma do Telegram.
  O PUT substitui a lista inteira, então comandos antigos somem.
- **Nomes:** o Discord aceita só letras minúsculas, números, `-` e `_`, até 32
  caracteres, e descrição de 1 a 100. Um comando que não cabe é pulado com
  aviso no log, sem derrubar o registro.
- **Autocompletar.** `core/closed_group/commands` ganha uma função pura de
  sugestões, `suggest(command, typed, contexto) -> List(String)`, que não sabe
  de canal. Ela casa o que foi digitado como prefixo, sem diferenciar
  maiúsculas nem acentos, e devolve no máximo 25 itens de até 100
  caracteres:

  | Comando | Sugestões |
  |---|---|
  | `/agenda` | `remover <id>` com os itens da agenda da própria pessoa |
  | `/esquecer` | `confirmo` |
  | `/model` | Os modelos configurados, como `<provedor> <modelo>` (o mesmo conjunto do seletor) |
  | `/uso` | `todos`, só para admin |
  | `/acesso` | `listar`, `adicionar`, `remover`, `chat …`; no `remover`, os principais com acesso |
  | `/teto` | `liberar` |
  | `/auditoria` | `20`, `50`, `100` |

  - **Papel antes de dado.** O contexto traz o papel de quem digita, resolvido
    pelo mesmo gate (aliases incluídos). Quem não tem acesso recebe lista
    vazia. Quem não é admin nunca recebe sugestão de comando de admin nem
    lista de principais.
  - **Rápido e sem efeito.** Só leitura de arquivos locais, sem LLM, sem
    ledger, sem passar pela fila do chat: a resposta sai do processo do
    `discord_channel`. Um erro devolve lista vazia.
- **Falha no registro** não impede o canal de subir: o log avisa, e o texto
  digitado (`/agenda`) continua funcionando, porque o núcleo lê o texto.

### 6.4 Mídia

- **Anexos.** O `discord_events.Message` passa a trazer `attachments`:

  | Campo | Uso |
  |---|---|
  | `url` | Assinada pelo CDN, expira em horas |
  | `content_type` | Declarado ao `inbound_media` |
  | `size` | Recusa antes de baixar acima de `inbound_media.max_bytes_for` |
  | `flags` da mensagem | Com `IS_VOICE_MESSAGE` (8192), o áudio é voz |
  | `filename` | Nome do arquivo |

  O adaptador baixa cada um pelo `inbound_media.fetch`, como o Telegram, e
  acrescenta as tags `[imagem:<id>]`, `[áudio:<id>]`… ao texto. Daí em diante
  é a PRD-A: leitura no chat lane, admissão, custo, transcrição devolvida.
- **Mapeamento:**

  | Discord | `inbound_media` |
  |---|---|
  | `image/*` | Image |
  | `audio/*`, voz | Audio (voz marcada como `voice`, para a transcrição devolvida) |
  | `video/*` | Video |
  | Outros | Document |
  | `sticker_items`, PNG e APNG | Sticker, baixado de `media.discordapp.net/stickers/<id>.png` |
  | `sticker_items`, Lottie (formato 3) | Ignorado: é JSON vetorial, não imagem |

- **Fora do laço de eventos** (decidido na execução, D-05). O laço que lê
  o gateway também confirma interações em até 3 s; uma mensagem com anexo
  vai para um processo próprio, que baixa e depois entrega ao turno. Uma
  mensagem de texto enviada logo depois de um vídeo grande pode chegar ao
  turno antes dele.
- **Só para quem tem acesso** (decidido na execução, D-05). Num servidor,
  qualquer pessoa manda anexos. Antes de baixar, `core/closed_group/lookup`
  confere acesso e chat sem efeito colateral (sem auditoria, sem aviso de
  recusa). Quem não tem acesso não custa download; o gate recusa o turno
  como sempre.
- **Só do CDN do Discord.** A URL do anexo passa pela proteção de URL da
  PRD-E e precisa ser de `cdn.discordapp.com` ou `media.discordapp.net`.
  Outra origem é recusada.

### 6.5 Agenda e identidade

- **Agenda no privado:** `private_delivery: True`. A entrega usa
  `private_chat_for` (`open-dm:<user_id>`), que o adaptador já resolve com
  `discord_rest.open_dm`. Conferir com teste que o chat aberto bate com o
  `dm:<channel_id>` que chega depois, senão a conversa se divide em duas.
- **Desvio na execução (D-06): o chat privado é a pessoa.** O adaptador
  chamava o privado de `dm:<id do canal de DM>`, e a agenda montava o chat
  com o id da pessoa, como no Telegram: a conversa se dividiria em duas, e o
  gate nem a reconheceria como privada. Agora o privado do Discord é
  `dm:<id da pessoa>`, o mesmo do `private_chat_for`. No envio, o adaptador
  abre (ou reaproveita, com cache) o canal de DM. A agenda passa a usar o
  `private_chat_for` do canal, em vez de supor o id da pessoa. Não há o que
  migrar: o Discord nunca recebeu mensagens.
- **Comentário errado no trait:** o cabeçalho de `traits/discord.gleam` diz
  `dm:<user_id>`, mas o adaptador usa `dm:<channel_id>`. Corrigir o
  comentário.
- **`/vincular`** já é genérico (PRD-I). Teste de ponta a ponta: código gerado
  no Telegram, usado no Discord, mesma agente.

### 6.6 Envio

- **`retry_after` sempre em segundos.** O Discord manda segundos, inteiro ou
  com fração. Os dois viram milissegundos, arredondados para cima; hoje o
  inteiro é lido como milissegundos.
- **Menções na resposta:** `allowed_mentions: {parse: []}` em toda mensagem
  da agente. A agente nunca dispara `@everyone`, `@here` nem menção a cargo,
  mesmo que o modelo escreva.

## 7. Histórias

- **D-01: gateway de verdade.** Conexão `stratus`, Hello, heartbeat com
  jitter, Identify, READY, encaminhamento de eventos ao `discord_channel`,
  JSON por `gleam/json`. Contra um gateway falso em `test/discord_fake.gleam`
  (mist com WebSocket), com as fixtures de `gateway_hello`, `gateway_ready` e
  `gateway_message_create`.
- **D-02: reconexão e prontidão.** Resume, op 7, op 9, backoff, códigos de
  fechamento fatais, `session_start_limit`, `channel/health` (6.1). Testado
  com o falso derrubando a conexão em cada ponto.
- **D-03: interações.** Confirmação em 3 s, edição da original e follow-up
  pelo token, queda para mensagem nova depois de 15 min (6.2). Trait
  `edits_interaction_source: True` (D5). Teste: seletor de modelo pelo
  Discord falso, do clique à mensagem editada.
- **D-04: comandos `/` e autocompletar.** Registro global e por servidor a
  partir de `core/closed_group/commands`, opção `args` com autocompletar (D6),
  nomes inválidos pulados, `suggest` no núcleo com o papel antes do dado
  (6.3). Teste: membro não vê `/acesso remover` com principais; admin vê.
- **D-05: mídia na entrada.** Anexos, voz, figurinha, limite de tamanho,
  origem só do CDN (6.4). Teste com cada tipo até a tag no texto, e um de
  ponta a ponta até a leitura de mídia com o Gemini falso.
- **D-06: agenda, identidade e envio.** `private_delivery`, conferência do
  chat aberto, `/vincular` Telegram ↔ Discord, `retry_after`,
  `allowed_mentions` (6.5, 6.6).
- **D-07: documentação.** Script de gravação em `dev/discord/` (D1),
  pronto para quando houver o bot, sem rodar; roteiro em `docs/operations/DISCORD.md`:
  - criar a aplicação e ligar a intenção;
  - convidar o bot com as permissões mínimas;
  - pôr o `.env` e autorizar o servidor com `/acesso chat discord:guild:<id>`.

  Também `supernova.yaml.example`, a linha do Discord no `STATUS.md` e o
  item no PENDENCIAS.

## 8. Critérios de aceite

| Critério | Meta |
|---|---|
| Gateway falso | READY marca o canal pronto; queda tira e volta a marcar; 4014 deixa `failed` com o motivo |
| Ponta a ponta, falso | Privado, canal de servidor autorizado, servidor não autorizado (sem resposta), menção, botão do seletor de modelo, `/agenda` como comando `/`, imagem, voz devolvida como transcrição |
| Interação | Confirmação enviada antes de 3 s, medido no falso com um turno de 10 s |
| Autocompletar | Sugestões filtradas pelo papel; nenhuma para quem não tem acesso |
| Identidade | Mesmo `agent_id` depois de `/vincular` entre Telegram e Discord |
| Cobertura | `discord_gateway` e `discord_channel` acima da média do projeto |
| Piloto (manual, pelo mantenedor) | Uma pessoa do grupo fechado fala com a agente pelo Discord, no privado e num canal; o `/health/ready` cai quando o token é revogado |

## 9. Riscos

- **Intenção privilegiada.** Acima de 100 servidores, a `MESSAGE_CONTENT`
  pede verificação do bot pelo Discord. O piloto está longe disso; se
  chegar, a agente passa a ver só o privado e as menções.
- **URL de anexo que expira.** O CDN assina a URL por algumas horas. A mídia é
  baixada na chegada; uma mensagem que fica na fila durável (PRD-E) mais que
  isso perde o anexo, e a agente responde só ao texto.
- **Fixtures de fevereiro.** Se o formato mudou, o falso passa e o real não. A
  D-07 grava de novo; até lá, o piloto manual é a conferência.
- **Turno longo e o token da interação.** Depois de 15 minutos a resposta vira
  mensagem nova, sem editar o menu. Aceito.
