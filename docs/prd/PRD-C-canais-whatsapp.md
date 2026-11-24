[PRD]
# PRD C: fundação de canais e WhatsApp via GOWA

> **Situação em 24/11/2026:** rascunho para o mantenedor. Direção aprovada
> (fundação primeiro, WhatsApp antes do Discord: há gente esperando no
> WhatsApp). D1 a D5 esperam decisão (seção 5). Depende da PRD-E (E-02, a
> proteção de URL).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio.

## 1. Contexto

**Canais.** Dos dez canais registrados, só o Telegram (long poll) e o sim
(HTTP local) recebem mensagens. Os outros, WhatsApp incluído, só enviam: o
`start` de cada adaptador descarta o `handler`, e não há servidor de
webhook (o `wisp` está no `gleam.toml` e nunca é importado). O núcleo
escolhe o roteador pelo nome do canal (`supernova.gleam:810-850`, `case
channel { "discord" -> … }`) e testa nomes em
`channel_common_router.gleam:1797` e `:2069`, contra o contrato escrito em
`channel/traits.gleam` ("the core never matches on channel names") e contra
a arquitetura de portas e adaptadores.

**WhatsApp.** O `whatsapp_adapter.gleam` (~1.000 linhas, 29 testes) foi
escrito para o GOWA (`go-whatsapp-web-multidevice`, MIT, whatsmeow). Foi
conferido contra a versão atual (v9.10.0, 18/11/2026,
`docs/webhook-payload.md` e `docs/openapi.yaml`):

| | GOWA v9.10 | Adaptador hoje |
|---|---|---|
| Envelope do webhook | `event`, `device_id`, `session_id`, `payload` | ✓ (sem `session_id`, inofensivo) |
| Mensagem | `id`, `chat_id`, `from`, `from_name`, `is_from_me`, `body`, `replied_to_id`, `timestamp` (RFC3339) | ✓ sem `timestamp` |
| Mídia | `image`/`audio`/`document` como texto (caminho) ou objeto (`path`, `url`, `caption`) | ✓ |
| Envio | `POST /send/message` (`phone`, `message`, `reply_message_id`), `X-Device-Id` | ✓ |
| Assinatura do webhook | HMAC SHA256 em `X-Hub-Signature-256` (`sha256=…`), segredo `WHATSAPP_WEBHOOK_SECRET` | ✗ |
| Autenticação do REST | basic auth (`APP_BASIC_AUTH`) | ✗ |
| Grupos | `chat_id` `…@g.us`, `mentions`, `from_lid` | ✗ |
| Conta | `device.logged_out`, `device.temporary_ban` | ✗ |

## 2. Objetivo

Um molde de canal de entrada, seguido por todos (o núcleo não conhece nomes
de canal), e o WhatsApp funcionando de ponta a ponta, com grupo fechado,
privado e grupos, imagens, e alerta quando a conta cai.

## 3. Fora de escopo

- Discord (PRD própria, depois desta).
- Áudio e documentos na entrada (D3); figurinhas.
- Canais experimentais além do WhatsApp (seguem só de saída).

## 4. Quality gates

Os de sempre (`AGENTS.md`). Testes sem rede: o GOWA nos testes é um
servidor falso (ou um transporte falso), nunca o real. Nada de WhatsApp de
verdade em teste.

## 5. Decisões do mantenedor

- **D1. Onde o webhook escuta.** (a) Porta própria (`channels.webhook.port`,
  ligada só na rede interna do compose); (b) a porta da saúde (8080).
  **Recomendação: (a)**: a de saúde é raspada pelo Prometheus e não deveria
  aceitar POST de fora.
- **D2. Quem é a pessoa: telefone ou LID.** O GOWA manda `from` com o
  telefone quando consegue resolver o LID, e o LID quando não. (a) Principal
  `whatsapp:<telefone>`; sem telefone, a mensagem é recusada com log e
  métrica, até resolver; (b) aceitar o LID como principal. **Recomendação:
  (a)**: dois principals para a mesma pessoa partem a memória e o `/esquecer`.
- **D3. Mídia na entrada.** Imagens nesta PRD (o caminho até o modelo já
  existe, `llm/tool_images`); áudio e documento depois. **Recomendação:
  assim.**
- **D4. Interface web do GOWA (pareamento por QR).** Só por túnel SSH, nunca
  exposta; `APP_UI_AUTO_UPDATE=false` (ela se atualiza do GitHub sozinha).
  **Recomendação: assim.**
- **D5. Versão do GOWA.** Imagem fixada por digest (v9.10.0), atualizada à
  mão lendo o changelog. **Recomendação: assim.**

## 6. Desenho

### 6.1 Tabela de canais

O `channel/registry` já tem a tabela dos que iniciam. Cada entrada passa a
trazer também a rota de entrada (`fn(ChannelInbound, Subject(StreamEvent))
-> Result(...)`); `supernova.gleam` consulta a tabela em vez do `case`.
Os testes de nome em `channel_common_router` viram traits
(`supports_interactions: Bool`; o id da mensagem de origem de uma
interação). Um teste de arquitetura falha se `supernova.gleam` ou
`channel_common_router.gleam` comparar o nome de um canal.

### 6.2 Servidor de webhook

`channel/webhook_server` (mist): rotas `POST /webhook/<canal>` declaradas
pelos adaptadores. Cada rota traz o verificador (HMAC, token) e o
tradutor do corpo para `ChannelInbound`. Comparação em tempo constante;
corpo até 1 MB; 401 sem assinatura válida, sem detalhes. O que passa vai
para o mesmo caminho do Telegram: fila durável, fila do chat, roteador.
Responde 200 assim que a mensagem está no inbox.

### 6.3 Proteção de URL dos adaptadores

O `check_base_url` do Telegram vira `channel/url_guard` (com a resolução de
nome da PRD-E): HTTPS, exceto loopback e os hosts internos listados em
`channels.internal_hosts` (o `gowa` do compose fala HTTP na rede interna).

### 6.4 WhatsApp

- **Entrada:** `POST /webhook/whatsapp`, HMAC com o segredo compartilhado.
  Eventos: `message` (texto, resposta, legendas; imagem por D3),
  `device.logged_out`, `device.temporary_ban`. Os outros são ignorados (e o
  GOWA configurado para não mandá-los). `is_from_me` é descartado.
- **Identidade (D2):** principal `whatsapp:<telefone>`; chat privado
  `…@s.whatsapp.net`, grupo `…@g.us` (chave `whatsapp:<jid do grupo>` em
  `access.allowed_chats`). Num grupo, segue a mesma regra de quando
  responder que o Telegram usa hoje (o executor confere em
  `channel_common_router` antes de implementar); `mentions` e
  `replied_to_sender` dão o que a regra precisa.
- **Saída:** basic auth e `X-Device-Id` em toda chamada; texto com
  `reply_message_id`.
- **Conta:** `device.logged_out` e `device.temporary_ban` viram métrica e
  alerta ao admin, e o `/health/ready` passa a refletir o canal.
- **Traits:** `traits/whatsapp.gleam` (privado, chave de grupo, entrega da
  agenda no privado, tamanho de mensagem, sem edição: a resposta não é
  transmitida aos pedaços).

### 6.5 GOWA no compose

Serviço `gowa`, imagem por digest (D5), volume `storages`, sem porta
publicada. Variáveis obrigatórias:

```
APP_BASIC_AUTH=<usuário:senha forte>
APP_ALLOW_UNAUTHENTICATED=false
APP_UI_AUTO_UPDATE=false
MCP_ENABLED=false
WHATSAPP_AUTO_REPLY=                  # vazio: o exemplo do GOWA responde sozinho
WHATSAPP_AUTO_MARK_READ=false
WHATSAPP_WEBHOOK=http://supernova:<porta>/webhook/whatsapp
WHATSAPP_WEBHOOK_SECRET=<segredo>
WHATSAPP_WEBHOOK_EVENTS=message,device.logged_out,device.temporary_ban
WHATSAPP_WEBHOOK_INCLUDE_OUTGOING=false
```

Roteiro de pareamento em `docs/operations/WHATSAPP.md` (túnel SSH até a
interface, QR ou código, conferir o webhook, `/acesso` da pessoa).

## 7. Histórias

- **C-01:** tabela de canais e traits; teste de arquitetura sem nomes no
  núcleo (6.1).
- **C-02:** servidor de webhook genérico (6.2), testado com um adaptador
  falso.
- **C-03:** proteção de URL dos adaptadores (6.3).
- **C-04:** WhatsApp, entrada e saída de texto, identidade, grupos, conta
  (6.4), contra um GOWA falso com payloads da v9.10.
- **C-05:** imagens na entrada (D3): baixar do GOWA com basic auth, limite de
  tamanho, ao modelo como imagem.
- **C-06:** compose, roteiro de pareamento, `supernova.yaml.example`,
  `ARCHITECTURE.md`, README (WhatsApp entra na tabela de canais).

## 8. Critérios de aceite

| Critério | Meta |
|---|---|
| Núcleo | nenhum `case` ou `==` sobre nome de canal fora de `channel/` e `adapters/` |
| Webhook | sem assinatura válida, 401; com, a mensagem chega ao inbox antes do 200 |
| WhatsApp falso | privado, grupo com menção, resposta citada, imagem, `is_from_me` ignorado, conta caída gera alerta |
| Piloto (manual, pelo mantenedor) | a Belle conversa com a Selene pelo WhatsApp |

## 9. Riscos

- **Banimento.** whatsmeow não é oficial; o número pode cair. O alerta de
  conta (6.4) avisa; o resto é risco aceito.
- **Terceiro no meio.** O GOWA guarda a sessão e vê o texto. Mitigação:
  versão fixa, interface fechada, MCP e auto-update desligados, rede
  interna.
- **Mudança de formato entre versões do GOWA.** Os testes usam payloads da
  versão fixada; atualizar o GOWA é atualizar os payloads de teste junto.
