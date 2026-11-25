//// Instructions for reading media (PRD-A), ported from Amélie's media
//// prompts (`core/prompt/montador.gleam`), which already work in use:
//// literal transcription, audio description with the speech transcribed,
//// documents read with what matters first. Amélie's persona and scope
//// rules are left out: here the reader only turns the medium into text,
//// and the agent answers.

import gleam/string
import supernova/core/preferences.{type Detail, Long, Normal, Short}

const language = "português do Brasil"

const no_intro = "\nNão use introduções conversacionais. Vá direto ao conteúdo."

pub const audio_start = "Transcrição do áudio"

pub const audio_end = "Fim da transcrição"

pub const video_start = "Audiodescrição do vídeo"

pub const video_end = "Fim da audiodescrição"

pub const document_start = "Descrição do documento"

pub const document_end = "Fim da descrição"

pub fn audio() -> String {
  "Transcreva este áudio em "
  <> language
  <> ". REGRAS OBRIGATÓRIAS:"
  <> "\n1. Produza SOMENTE a transcrição literal do que foi dito."
  <> "\n2. Use pontuação correta (vírgulas, pontos, interrogações, exclamações) para refletir a fala."
  <> "\n3. Separe em parágrafos por mudança de assunto ou pausa longa."
  <> "\n4. NÃO inclua resumo, análise, comentários, descrições do áudio ou formatação markdown."
  <> "\n5. NÃO inclua timestamps."
  <> "\n6. NÃO cumprimente ou se apresente."
  <> "\n7. Inicie a resposta exatamente com \""
  <> audio_start
  <> "\" seguido de quebra de linha."
  <> "\n8. Finalize exatamente com \""
  <> audio_end
  <> "\"."
}

/// Amélie's detail modes, appended to descriptions.
pub fn detail_suffix(detail: Detail) -> String {
  case detail {
    Long ->
      "\n- Forneça uma descrição completa e detalhada, incluindo todos os elementos visíveis, cores, textos, posições e contexto."
    Short -> "\n- Seja concisa e objetiva na descrição."
    Normal -> ""
  }
}

/// Sent to the agent's model with an image the person sent (PRD-A, A-08):
/// Amélie's audio description rules, for when the person asked nothing
/// else about it. Only in the turn; the history keeps `[imagem]` and the
/// agent's answer.
pub fn image_guidance(detail: Detail) -> String {
  "[Instrução para esta mensagem: a pessoa mandou imagem. Se ela não pediu outra coisa sobre a imagem, faça a audiodescrição em "
  <> language
  <> ". REGRAS:"
  <> "\n- Comece identificando o tipo de imagem (fotografia, ilustração, gráfico, mapa, captura de tela, etc.)."
  <> "\n- Descreva do geral ao específico: contexto geral primeiro, depois detalhes."
  <> "\n- Inclua: cores, posições espaciais, textos visíveis (transcreva-os na íntegra), expressões faciais, ações e cenário."
  <> "\n- Identifique pessoas por nome (se reconhecíveis) ou por atributo físico visível."
  <> "\n- Seja objetiva: descreva apenas o que é visível, sem interpretar intenções ou estados mentais. Não censure conteúdo."
  <> "\n- Use tempo presente e voz ativa; sem tabelas nem decorações (a resposta pode ser ouvida por leitor de tela)."
  <> detail_suffix(detail)
  <> "\nSe ela perguntou algo sobre a imagem, responda à pergunta.]"
}

pub fn video() -> String {
  video_with(Normal)
}

pub fn video_with(detail: Detail) -> String {
  "Faça a audiodescrição e a transcrição deste vídeo em "
  <> language
  <> ". REGRAS:"
  <> "\n- Descreva ações, personagens, cenários e mudanças de cena em sequência cronológica."
  <> "\n- Inclua: cores, posições espaciais, expressões faciais, gestos, vestuário e ambiente."
  <> "\n- TRANSCRIÇÃO OBRIGATÓRIA DAS FALAS E ÁUDIO: se houver qualquer fala, diálogo, narração ou explicação audível, transcreva na íntegra tudo o que for dito, numa seção clara \"Transcrição da fala:\". NÃO resuma as falas. Se o vídeo for mudo, não invente, não deduza e não mencione som ou fala."
  <> "\n- Transcreva na íntegra qualquer texto visível na tela (títulos, legendas, créditos, placas)."
  <> "\n- Identifique pessoas por nome (se reconhecíveis) ou por atributo físico visível."
  <> "\n- Seja objetiva: descreva apenas o observável, sem interpretar intenções ou estados mentais. Não censure conteúdo."
  <> "\n- Use tempo presente, voz ativa e terceira pessoa. Não inclua timestamps."
  <> detail_suffix(detail)
  <> no_intro
  <> "\nInicie sua resposta exatamente com \""
  <> video_start
  <> "\" e finalize com \""
  <> video_end
  <> "\"."
}

pub fn document() -> String {
  document_with(Normal)
}

pub fn document_with(detail: Detail) -> String {
  "Leia este documento em "
  <> language
  <> " e devolva o seu conteúdo. REGRAS:"
  <> "\n- Identifique a natureza do documento (boleto, conta, fatura, comprovante, contrato, relatório, carta, etc.)."
  <> "\n- Se for conta, boleto ou cobrança, destaque primeiro: emissor ou beneficiário; valor total; vencimento; linha digitável completa ou chave PIX copia-e-cola, sem omitir dígitos; pagador."
  <> "\n- Se for contrato ou documento jurídico ou administrativo, destaque primeiro: as partes; o objetivo; prazos, vigência, valores e cláusulas essenciais."
  <> "\n- Depois, transcreva o texto do documento, na ordem, sem resumir; em documentos muito longos, transcreva o que couber e diga onde parou."
  <> "\n- Sem tabelas com barras verticais; prefira texto corrido ou listas simples (a resposta pode ser ouvida por leitor de tela)."
  <> detail_suffix(detail)
  <> no_intro
  <> "\nInicie sua resposta exatamente com \""
  <> document_start
  <> "\" e finalize com \""
  <> document_end
  <> "\"."
}

/// The text between the reader's start and end markers, without them.
pub fn strip_markers(text: String, start: String, end: String) -> String {
  let text = string.trim(text)
  let text = case string.starts_with(text, start) {
    True -> string.drop_start(text, string.length(start))
    False -> text
  }
  let text = string.trim(text)
  let text = case string.ends_with(text, end) {
    True -> string.drop_end(text, string.length(end))
    False -> text
  }
  string.trim(text)
}
