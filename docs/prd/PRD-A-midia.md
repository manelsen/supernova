[PRD]
# PRD A: a agente abre tudo o que a pessoa manda

> **Situação em 24/11/2026:** D1 a D5 decididos pelo mantenedor; D6 aberta
> (seção 5). O desenho das seções 6 e 7 será revisto para refletir D1 e
> D4 (texto em vez de mídia crua para áudio, vídeo e documento) quando D6
> fechar. Depende da PRD-C (capacidade de mídia, C-05).

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
- **D6. (aberta) Quando transcrever de volta e quando conversar.**
  Proposta:
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
  image:    { reader: turn }                               # o modelo da agente
  audio:    { reader: model, model: gemini/<flash-lite> }  # D1 (a)
  video:    { reader: model, model: gemini/<flash-lite> }
  document: { reader: model, model: gemini/<flash-lite> }
  # alternativa para áudio:
  # audio:  { reader: transcribe, model: groq/whisper-large-v3-turbo }
```

Os leitores:

- `turn`: a mídia vai ao modelo da agente.
- `model`: o turno daquela mensagem roda no modelo dado (D1 a).
- `transcribe`: o áudio vira texto antes do turno.
- `off`: a agente recebe a nota de que não abre aquele tipo.

O `check-config` recusa uma combinação que o modelo não aceita (por
exemplo, áudio com `reader: turn` no DeepSeek).

### 6.2 Capacidade de mídia (estende a C-05)

`inbound_media` passa a guardar qualquer tipo, com o tipo conferido pelos
bytes e pelo MIME que o canal informa: imagem, áudio (OGG/Opus, MP3, M4A,
AAC, WAV), vídeo (MP4, 3GP, WebM, MOV) e documento (PDF, Office, texto).
O teto de tamanho é o do leitor configurado: 20 MB inline, ou 2 GB pela
Files API do Gemini. O arquivo é gravado em disco enquanto chega, nunca
inteiro na memória. A tag no texto ganha o tipo e os metadados:
`[áudio:<id> 0:42]`, `[documento:<id> contrato.pdf]`.

### 6.3 Provedores

- **Gemini nativo** (`llm/providers/gemini`): mensagens, tools, imagem,
  áudio, vídeo e documento como partes `inline_data`; acima de 20 MB,
  sobe pela Files API e usa `file_data`. A Supernova apaga o arquivo no
  Google depois do turno (D3).
- **Groq** (`llm/providers/groq`): só `/openai/v1/audio/transcriptions`,
  com `language: pt` (o `pt` não está documentado; testar na execução).
- O **DeepSeek direto** (Files API para PDF) fica de fora: o Gemini cobre
  documento.

### 6.4 O turno

O roteador comum lê as tags da mensagem e escolhe o leitor de cada mídia:

- `turn` e `model` montam a mensagem com as partes;
- `model` troca o modelo daquele turno (como o `/model`, só para essa
  mensagem);
- `transcribe` chama o Whisper antes e põe o texto no lugar da tag.

Admissão no ledger antes da chamada, com a estimativa de tokens da
documentação: áudio 32 tokens/s, vídeo cerca de 100 tokens/s, PDF cerca
de 560 tokens/página. A cobrança vai para o orçamento da pessoa. Se a
admissão negar (orçamento), a agente recebe a nota e responde.

### 6.5 WhatsApp

O tradutor reconhece `audio`, `video`, `document` e `sticker` (texto ou
objeto com `path`, legenda e nome do arquivo). Localização e contato viram
nota. Nada mais é descartado por "mensagem vazia".

## 7. Histórias

- **A-01:** nada some: todo tipo vira tag ou nota, e a agente responde
  ("[um áudio que ainda não consigo abrir]") com o leitor `off`. Isso já
  resolve o silêncio, antes de qualquer provedor novo.
- **A-02:** `inbound_media` para todos os tipos, gravando em disco enquanto
  chega, com metadados (duração, páginas, nome).
- **A-03:** provedor Gemini nativo: chat com tools e as quatro mídias
  inline, contra um servidor falso.
- **A-04:** Files API do Gemini: envio acima de 20 MB, apagado depois do
  turno e no `/esquecer`.
- **A-05:** configuração `media.*`, leitores `turn`, `model` e `off`, troca
  de modelo no turno, admissão no ledger por tipo, `check-config`.
- **A-06:** Groq Whisper e o leitor `transcribe`.
- **A-07:** WhatsApp: áudio, vídeo, documento e figurinha pelo GOWA;
  localização e contato como nota.
- **A-08:** documentação: config, custos por tipo, o que fica na memória.

## 8. Critérios de aceite

| Critério | Meta |
|---|---|
| Mídia que some | nenhuma: todo tipo vira tag ou nota |
| Áudio do WhatsApp (OGG/Opus) | chega ao modelo configurado, e a agente responde sobre o conteúdo (servidor falso nos testes; manual no piloto) |
| Arquivo acima de 20 MB | vai pela Files API e é apagado depois |
| Custo | admitido no ledger antes da chamada, no orçamento da pessoa |
| Piloto (manual) | a Belle manda um áudio e a agente dela responde ao que ela disse |

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
