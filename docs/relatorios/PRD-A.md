# PRD-A: relatório final

[PRD](../prd/PRD-A-midia.md) · PR #72 · 25/11

## Resumo

A agente passou a abrir tudo o que a pessoa manda, no WhatsApp e no Telegram,
e a responder em voz quando a pessoa pede. Nada que chega some em silêncio: se
não dá para ler, chega uma nota com o motivo, e a agente responde sobre ela.

| A pessoa manda | A agente |
|---|---|
| mensagem de voz, áudio | ouve: transcrição literal (prompt da Amélie), que fica na memória |
| áudio encaminhado | devolve a transcrição, sem passar pelo modelo |
| vídeo | assiste: audiodescrição com as falas transcritas |
| documento (PDF, Office, texto) | lê o essencial primeiro (valor, vencimento, linha digitável completa; partes e prazos) e depois o texto |
| imagem, figurinha estática | vê e descreve, se a pessoa não perguntou outra coisa |
| figurinha animada | lê até 8 quadros, em ordem, e descreve a animação |
| localização, contato, enquete | recebe como texto |

Os comandos de como a agente responde ficam guardados como preferência de cada
pessoa e são apagados no `/esquecer`: `/voz` (TTS do Gemini, voz Sulafat),
`/transcricao`, `/curto`, `/longo` e `/cego`. A queda do WhatsApp avisa pelo
Telegram, nunca pelo canal que caiu, e já leva o código de reconexão; `/parear`
gera um novo e é só para admins.

## Medição final

Não há bancada nesta PRD. O que foi medido é a suíte e a construção da imagem.

| | Valor |
|---|---|
| Testes | **2815** |
| Cobertura de linha | **81,07%** |
| Imagem Docker | construída localmente, com Pillow 12.2.0; **não publicada, nem enviada** |

A imagem foi o teste real do decompositor de figurinha animada: o FFI da
Supernova, chamado dentro da imagem, compôs os quadros da figurinha de teste.

## Critérios da PRD (seção 8)

| Critério | Meta | Resultado |
|---|---|---|
| Mídia que some | nenhuma: todo tipo vira tag ou nota | **Atingido** em `test/channel/inbound_media_test.gleam`, `inbound_media_kinds_test.gleam` e `test/e2e/media_e2e_test.gleam`; chave ausente, tipo desligado, orçamento estourado e erro do provedor viram nota com o motivo. |
| Áudio do WhatsApp (OGG/Opus) | vira transcrição literal no texto do turno e na memória | **Atingido com fixture real**, gravada contra a API (`dev/gemini/gravar.py`); servidor falso nos testes. Não exercitado no piloto. |
| Áudio encaminhado | volta como transcrição | **Atingido** em `test/channel/voice_text_test.gleam`. |
| `/voz` | a resposta chega como mensagem de voz | **Atingido** em `test/channel/voice_test.gleam`; a Belle escolheu a voz Sulafat entre oito lendo português. |
| Arquivo acima de 20 MB | vai pela Files API e é apagado depois | **Atingido** em `test/llm/gemini_media_test.gleam`; a gravação corrigiu duas suposições (partes de 8 MiB, arquivo removido responde 403). |
| Custo | admitido no ledger antes da chamada, no orçamento da pessoa | **Atingido**; cada leitura e cada fala passa pela admissão e é cobrada da pessoa. A mídia de um estranho não é lida e não gasta nada. |
| Piloto (manual) | a Belle, com `/voz`, fala com a agente dela e ouve a resposta | **Não feito.** Nada rodou contra o WhatsApp real. |

## O que mudou, por história

| História | Commit | O que fez |
|---|---|---|
| A-01 | `7977490` | nada que a pessoa manda some em silêncio no WhatsApp |
| A-02 | `ff42709` | capacidade de mídia para todos os tipos |
| A-03 | `c679043` | cliente Gemini para ler mídia, testado contra respostas reais |
| A-04 | `0aea596` | áudio, vídeo e documento viram texto antes do turno |
| A-05 | `242651b` | transcrição de volta, para quem prefere ler |
| A-06 | `086e7c3` | `/voz`: a agente responde com mensagem de voz |
| A-07 | `4c43c05` | documentação: o que a agente abre, os comandos, a voz |
| A-08, A-09 | `da20329` | audiodescrição de imagem e nível de detalhe por pessoa |
| A-10 | `a097fdc` | figurinha animada lida quadro a quadro |
| A-11 | `6eabcca` | a mesma leitura de mídia no Telegram, com `getFile` |
| A-12 | `c86dbe8` | queda do WhatsApp avisada pelo Telegram, com o código de reconexão |

## Corridas resolvidas

Não houve corrida nova nesta PRD. As que apareceram no caminho ficaram na
PRD-C, com quem esta compartilhou a pilha.

## O que fica

- **Resposta do `login-with-code`** segue o openapi do GOWA, sem teste: gravar
  a resposta exigiria derrubar a sessão de propósito.
- **Nada rodou contra o WhatsApp de verdade.** O pareamento é manual.
- **Suposições da documentação do Gemini.** Ela se contradiz sobre o limite
  inline (20 MB nas páginas de áudio e vídeo, 100 MB na de arquivos). O código
  usa 20 MB, conferido contra a API real.
- **Privacidade.** O Google guarda o arquivo da Files API por 48 h, se não for
  apagado antes. A Supernova apaga logo depois do turno.
- **Custo.** Um vídeo de uma hora custa cerca de 360 mil tokens. A admissão e
  o orçamento da pessoa seguram, e a agente avisa quando nega.
- **Voz variando entre modelos.** O núcleo e a memória vão no prompt de
  qualquer modelo; a diferença de estilo é o preço de ouvir direto.
