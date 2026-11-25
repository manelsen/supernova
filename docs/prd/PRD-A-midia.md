[PRD]
# PRD A: a agente abre tudo o que a pessoa manda

> **Situação em 25/11/2026:** executada (A-01 a A-12, PR #72), com as
> decisões D1 a D6 (seção 5). Voz padrão: Sulafat, escolhida pela Belle.
> Depende da PRD-C (capacidade de mídia, C-05).

> **Executor:** agente autônomo. Leia este documento inteiro antes de começar.
> Execute as histórias **na ordem**. Cada história termina com os quality
> gates verdes e um commit próprio.

## 1. Contexto

Hoje, no WhatsApp, a imagem chega ao modelo (C-05). Áudio, vídeo e
documento sem legenda **somem em silêncio**: o tradutor os descarta como
mensagem vazia. Com legenda, chega só a legenda, e a agente não sabe que
havia um arquivo junto. Figurinha, localização e contato também somem.

A Supernova é de agentes pessoais "capazes de tudo" (mantenedor, 24/11):
a agente tem de ouvir o áudio, ver o vídeo e ler o documento, com o modelo
que o mantenedor escolher para cada tipo, sem tetos além dos do modelo.

**O que os provedores aceitam** (documentação oficial conferida em 24/11):

| Provedor | Imagem | Áudio | Vídeo | Documento | Limites |
|---|---|---|---|---|---|
| Gemini (API nativa) | ✓ | ✓ (OGG e Opus na lista) | ✓ | PDF nativo; DOCX, XLSX, PPTX, ODT; TXT, MD e HTML como texto | 20 MB inline por requisição; Files API até 2 GB por arquivo, guardado 48 h; 9,5 h de áudio; PDF até 1000 páginas |
| Gemini (endpoint OpenAI) | ✓ | ✓ (`input_audio`, só `wav` no exemplo) | não documentado | não documentado | |
| DeepSeek `deepseek-flash` (V4.1) | ✓ | ✗ no chat (há ASR à parte) | ✗ | PDF, Word e PowerPoint pela Files API | imagem até 32 MiB; documento até 100 MiB e 1000 páginas |
| Mistral | ✓ (inclusive o DeepSeek V4.1 Flash servido por ela, que é o piloto) | Voxtral (transcrição; áudio no chat não conferido) | não documentado | OCR à parte | imagem até 10 MB, 8 por requisição |
| Groq | | Whisper (só transcrição): `ogg` na lista; turbo a US$ 0,04/h, v3 a US$ 0,111/h | | | 25 MB por upload, 100 MB por URL; mínimo cobrado de 10 s |

A Supernova não tem provedor Gemini para conversa (só para o Decision e os
embeddings da memória) nem provedor Groq.

## 2. Objetivo

Nenhuma mídia some. Cada tipo grande (imagem, áudio, vídeo, documento) tem
um leitor configurável. A agente abre o que chega com o modelo escolhido e
responde a respeito. O que não puder ser aberto vira uma nota para a
agente ("[um áudio que não consegui abrir]"), nunca silêncio.

## 3. Fora de escopo

- Responder com áudio (voz da agente).
- Mídia de saída nova (a agente já envia imagem e arquivo).
- Figurinhas animadas, localização e contato como conteúdo: viram uma nota
  curta ("[a pessoa mandou uma localização]"), nesta PRD.

## 4. Quality gates

Os de sempre (`AGENTS.md`). Nenhum teste chama provedor de verdade: os
provedores novos são testados contra servidores falsos (como o GOWA
falso), com payloads copiados da documentação.

## 5. Decisões do mantenedor (24/11)

- **D1. Áudio é transcrito.** A transcrição tem dois usos:
  - **devolver o texto à pessoa.** Caso de uso: pessoas autistas, para quem
    áudios longos, com pausas, idas e voltas, serializam a atenção, e
    texto se lê em paralelo;
  - **conversar:** a transcrição entra no turno como se a pessoa tivesse
    escrito, e fica na memória (D4).
  - Volta completa em áudio (ouvir, responder, falar), para quem tem baixa
    visão ou é cega, é desejada; ver D6.
- **D2. Gemini pela API do AI Studio** (`generativelanguage.googleapis.com`,
  nativa, com Files API).
- **D3. Arquivos acima de 20 MB** vão pela Files API, que os guarda por 48
  h; a Supernova apaga logo depois do turno e no `/esquecer`. Ciente.
- **D4. Na memória fica o texto:** a transcrição do áudio, a audiodescrição
  e transcrição do vídeo, o texto do documento.
- **D5. Modelos:**
  - imagem no modelo da agente: o DeepSeek do piloto vê imagem, sem chamada
    extra. Custo comparável ao Flash-Lite, cerca de US$ 0,0003 por imagem
    de entrada nos dois, e saída mais barata no DeepSeek;
  - áudio, vídeo e documento no `gemini-3.5-flash-lite`, com os prompts da
    Amélie (transcrição literal, audiodescrição com transcrição das falas),
    já provados em uso. Áudio pelo Flash-Lite custa cerca de US$ 0,05/h
    (25 tokens/s a US$ 0,30/M);
  - TTS no `gemini-3.8-flash-lite-tts` (fala português, 30 vozes, WAV 24
    kHz; cerca de US$ 0,01 por minuto de fala até 31/12/2026, o dobro
    depois). O GOWA manda como mensagem de voz (`ptt: true`) e converte
    para OGG/Opus com ffmpeg. O TTS do DeepSeek não fala português;
  - tudo trocável na configuração (Groq Whisper como `transcribe`, por
    exemplo).
- **D6. Quando transcrever de volta e quando conversar** (aprovada):
  - áudio **encaminhado** volta como transcrição (se o GOWA informar o
    encaminhamento; conferir na execução);
  - áudio **da própria pessoa** é conversa;
  - `/voz` liga as respostas em áudio;
  - `/transcricao` devolve também a transcrição dos áudios da própria
    pessoa.

**Base de código:** o cliente Gemini nativo da Amélie
(`~/git/amelie/src/adaptadores/gemini_http.gleam`: `inline_data`, Files API
com upload, espera e remoção), os prompts de mídia
(`core/prompt/montador.gleam`) e o saneamento para leitor de tela e voz
(`core/acessibilidade.gleam`) são portados, adaptados ao kernel da
Supernova (admissão no ledger, orçamento da pessoa, tempo-limite).

## 6. Desenho

### 6.1 Configuração

```yaml
media:
  # Quem lê áudio, vídeo e documento.
  reader: gemini/gemini-3.5-flash-lite
  # A voz das respostas de quem pediu /voz.
  speech: gemini/gemini-3.8-flash-lite-tts
  voice: Kore
  image: turn       # turn: o modelo da agente vê | read: o leitor descreve | off
  audio: read       # read: transcreve | off
  video: read       # read: audiodescrição e transcrição das falas | off
  document: read    # read: texto do documento | off
```

O `check-config` recusa `image: turn` quando o modelo da agente não vê
imagem, e `read` sem leitor configurado com chave.

### 6.2 Do arquivo ao texto

A mídia chega pela capacidade de mídia (C-05), estendida a todos os tipos:
arquivo temporário gravado enquanto chega, tipo conferido pelos bytes e
pelo MIME, e a tag no texto (`[áudio:<id> 0:42]`).

Antes do turno, cada mídia `read` é lida pelo leitor com os prompts da
Amélie:

- **áudio:** transcrição literal;
- **vídeo:** audiodescrição com transcrição obrigatória das falas, sem
  inventar som em vídeo mudo;
- **documento:** o texto.

O texto toma o lugar da tag ("[áudio de 0:42, transcrito]\n…"). Daí em
diante, o turno, a memória, o `buscar_conversa` e o `/esquecer` lidam
com texto (D4).

Até 20 MB, a mídia vai `inline_data`; acima, pela Files API, apagada
depois.

Cada leitura passa pelo kernel:

- admissão no ledger antes, com a estimativa da documentação (25
  tokens/s de áudio, 70 tokens/quadro de vídeo, cerca de 560
  tokens/página);
- cobrança no orçamento da pessoa;
- tempo-limite.

Se a leitura falhar ou for negada, a tag vira uma nota ("[um áudio que
não consegui ouvir: <motivo curto>]").

### 6.3 Transcrição de volta (D6)

- **Áudio encaminhado** (o canal informa): a agente responde com a
  transcrição ("Transcrição do áudio" … "Fim da transcrição"), sem turno
  do modelo. A troca fica no histórico.
- **Áudio da própria pessoa:** é conversa, e o texto vai ao turno. Com
  `/transcricao` ligado, a transcrição sai antes da resposta.
- `/transcricao` e `/voz` são preferências da pessoa, guardadas na pasta
  dela e apagadas no `/esquecer`.

### 6.4 Voz (D6)

Com `/voz` ligado, a resposta da agente:

1. passa pelo saneamento para voz da Amélie (sem linhas decorativas,
   tabelas nem emojis repetidos);
2. vira áudio no TTS (WAV, 24 kHz);
3. é enviada como mensagem de voz pelo canal (trait `sends_voice`; no
   WhatsApp, `/send/audio` com `ptt: true`, convertido pelo GOWA).

O texto também fica no histórico. O TTS passa pelo ledger como as outras
chamadas.

### 6.5 Base

O cliente Gemini nativo da Amélie é portado como `llm/gemini_media`:

- `generateContent` com `inline_data` e `file_data`;
- Files API com upload, espera e remoção;
- TTS.

Também vêm os prompts de mídia (`core/media_prompts`) e o saneamento
para voz (`channel/voice_text`).

## 7. Histórias

- **A-01:** nada some. O WhatsApp reconhece áudio, vídeo, documento,
  figurinha, localização e contato. Todo tipo vira tag ou nota, e a
  agente responde ("[a pessoa mandou um áudio, que ainda não consigo
  ouvir]").
- **A-02:** capacidade de mídia para todos os tipos: gravação enquanto
  chega, tipo, duração, páginas, nome do arquivo.
- **A-03:** cliente Gemini (portado da Amélie) contra um servidor falso:
  `inline_data`, Files API (upload, espera, remoção), extração da
  resposta, erros.
- **A-04:** configuração `media.*`, leitores `read` e `off`, prompts da
  Amélie, o texto no lugar da tag, admissão e cobrança no ledger, nota de
  falha, `check-config`.
- **A-05:** transcrição de volta: áudio encaminhado e `/transcricao`.
- **A-06:** voz: TTS, saneamento, `/voz`, envio como mensagem de voz pelo
  GOWA.
- **A-08:** audiodescrição de imagem pelo leitor (`image: read`, prompt da
  Amélie): a descrição estruturada no texto e na memória.
- **A-09:** preferências de resposta por pessoa: `/curto`, `/longo`,
  `/cego` (detalhe da audiodescrição), junto de `/transcricao` e `/voz`.
- **A-10:** figurinha animada: convertida em vídeo e lida pelo leitor.
- **A-11:** mídia no Telegram (`getFile` da Bot API), no mesmo caminho.
  Fica por último: o foco é o WhatsApp.
- **A-12:** WhatsApp caiu: o aviso vai pelo Telegram (nunca pelo canal que
  caiu) e, quando é logout, já leva o código de pareamento pedido ao GOWA
  (`/app/login-with-code`); `/parear` para admins gera outro. Suspensão
  temporária só avisa até quando.
- **A-07:** documentação: configuração, custos, o que fica na memória,
  os comandos. Fecha a PRD.

A-08 a A-12 entraram em 24/11 para chegar perto da paridade com a Amélie
no WhatsApp (decisão do mantenedor: foco no WhatsApp; avisos pelo
Telegram).

## 8. Critérios de aceite

| Critério | Meta |
|---|---|
| Mídia que some | nenhuma: todo tipo vira tag ou nota |
| Áudio do WhatsApp (OGG/Opus) | vira transcrição literal no texto do turno e na memória (servidor falso nos testes; manual no piloto) |
| Áudio encaminhado | volta como transcrição |
| `/voz` | a resposta chega como mensagem de voz |
| Arquivo acima de 20 MB | vai pela Files API e é apagado depois |
| Custo | admitido no ledger antes da chamada, no orçamento da pessoa |
| Piloto (manual) | a Belle, com `/voz`, fala com a agente dela e ouve a resposta |

## 9. Riscos

- **Custo.** Um vídeo de uma hora custa cerca de 360 mil tokens. A admissão
  e o orçamento da pessoa seguram, e a agente avisa quando negar.
- **Privacidade.** O Google guarda o arquivo da Files API por 48 h, se não
  for apagado antes (D3). A Supernova apaga logo depois do turno.
- **Voz variando entre modelos** (D1 a): o núcleo e a memória vão no prompt
  de qualquer modelo; a diferença de estilo é o preço de ouvir direto.
- **Documentação inconsistente.** A do Gemini se contradiz sobre o limite
  inline (20 MB nas páginas de áudio e vídeo, 100 MB na de arquivos). Usar
  20 MB até testar.
