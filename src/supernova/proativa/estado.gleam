//// PRD-Q: when the agent may start a conversation. Pure rules over a
//// small per-person state kept in `<self>/proativa.json`.
////
//// - On by default; the person turns it off (D2).
//// - A daily ceiling that starts at 3, rises to 6 when the person answers
////   and falls to 1 when they ignore (D3). The waking hours are split in
////   as many slots as the ceiling; each slot opens once a day, at a moment
////   of its own.
//// - Silence at night, 22h to 8h by default, in the person's time (D3).
//// - Never two in a row without an answer (Q-I2).
//// - Sensitive subjects: light by default (D5).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import supernova/core/agent_identity

pub const teto_inicial = 3

pub const teto_minimo = 1

pub const teto_maximo = 6

/// Answers in a row that raise the ceiling by one.
pub const respostas_para_subir = 3

/// A proactive message unanswered this long counts as ignored.
pub const ignorada_apos_ms = 86_400_000

/// How the agent treats sensitive subjects on its own (D5).
pub type Assuntos {
  /// It may ask lightly how the person is, never the detail.
  Leve
  /// It may come back to anything the person talked about.
  Livres
  /// Only what the person brings; nothing sensitive on its own.
  SoMeus
}

pub type Estado {
  Estado(
    ligada: Bool,
    teto: Int,
    /// Silence from this hour (0-23) until `silencio_ate`, local time.
    silencio_de: Int,
    silencio_ate: Int,
    assuntos: Assuntos,
    /// The local day the slots below belong to (`YYYY-MM-DD`).
    dia: String,
    /// Slots of `dia` already used, spoken or not.
    tentativas: Int,
    /// The last proactive message still has no answer.
    aguardando: Bool,
    ultima_at: Int,
    /// Answers in a row to proactive messages.
    respondidas: Int,
    /// The unanswered one already lowered the ceiling.
    penalizada: Bool,
  )
}

pub fn inicial() -> Estado {
  Estado(
    ligada: True,
    teto: teto_inicial,
    silencio_de: 22,
    silencio_ate: 8,
    assuntos: Leve,
    dia: "",
    tentativas: 0,
    aguardando: False,
    ultima_at: 0,
    respondidas: 0,
    penalizada: False,
  )
}

// ============================================================================
// Time
// ============================================================================

/// Minutes since local midnight.
pub fn minuto_local(now_ms: Int, offset_minutes: Int) -> Int {
  let minutes = now_ms / 60_000 + offset_minutes
  { minutes % 1440 + 1440 } % 1440
}

/// The local day as `YYYY-MM-DD`.
pub fn dia_local(now_ms: Int, offset_minutes: Int) -> String {
  let days = { now_ms / 60_000 + offset_minutes } / 1440
  civil(days)
}

/// Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn civil(days: Int) -> String {
  let z = days + 719_468
  let era = case z >= 0 {
    True -> z / 146_097
    False -> { z - 146_096 } / 146_097
  }
  let doe = z - era * 146_097
  let yoe = { doe - doe / 1460 + doe / 36_524 - doe / 146_096 } / 365
  let doy = doe - { 365 * yoe + yoe / 4 - yoe / 100 }
  let mp = { 5 * doy + 2 } / 153
  let d = doy - { 153 * mp + 2 } / 5 + 1
  let m = case mp < 10 {
    True -> mp + 3
    False -> mp - 9
  }
  let y = yoe + era * 400 + bool_int(m <= 2)
  int.to_string(y) <> "-" <> pad2(m) <> "-" <> pad2(d)
}

fn bool_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

fn pad2(n: Int) -> String {
  string.pad_start(int.to_string(n), 2, "0")
}

/// Whether a local minute falls in the silence (which may cross midnight).
pub fn em_silencio(minuto: Int, de: Int, ate: Int) -> Bool {
  let inicio = de * 60
  let fim = ate * 60
  case inicio == fim {
    True -> False
    False ->
      case inicio < fim {
        True -> minuto >= inicio && minuto < fim
        False -> minuto >= inicio || minuto < fim
      }
  }
}

// ============================================================================
// The window
// ============================================================================

pub type Janela {
  /// A slot is open: the agent may decide to speak.
  Aberta
  Fechada(motivo: String)
}

/// The state for today: a new local day starts with every slot free.
pub fn para_o_dia(estado: Estado, dia: String) -> Estado {
  case estado.dia == dia {
    True -> estado
    False -> Estado(..estado, dia: dia, tentativas: 0)
  }
}

/// Whether the agent may decide to speak now. `chave` spreads the slots of
/// different people (their principal).
pub fn janela(
  estado: Estado,
  now_ms: Int,
  offset_minutes: Int,
  chave: String,
) -> Janela {
  let minuto = minuto_local(now_ms, offset_minutes)
  let estado = para_o_dia(estado, dia_local(now_ms, offset_minutes))
  case estado.ligada {
    False -> Fechada("desligada")
    True ->
      case em_silencio(minuto, estado.silencio_de, estado.silencio_ate) {
        True -> Fechada("silêncio")
        False ->
          case estado.aguardando {
            True -> Fechada("aguardando resposta")
            False ->
              case estado.tentativas >= estado.teto {
                True -> Fechada("teto do dia")
                False ->
                  case
                    minuto >= hora_do_slot(estado, estado.tentativas, chave)
                  {
                    True -> Aberta
                    False -> Fechada("ainda não")
                  }
              }
          }
      }
  }
}

/// The local minute slot `indice` opens today: the waking hours split in
/// `teto` slots, each opening at a moment of its own inside it.
pub fn hora_do_slot(estado: Estado, indice: Int, chave: String) -> Int {
  let acordado = { estado.silencio_de - estado.silencio_ate + 24 } % 24 * 60
  let acordado = case acordado {
    0 -> 1440
    n -> n
  }
  let largura = int.max(1, acordado / int.max(1, estado.teto))
  let inicio = estado.silencio_ate * 60 + indice * largura
  let atraso =
    espalhar(
      chave <> "|" <> estado.dia <> "|" <> int.to_string(indice),
      largura,
    )
  { inicio + atraso } % 1440
}

/// A number in [0, limit) from a text, stable across restarts.
fn espalhar(texto: String, limite: Int) -> Int {
  phash2(texto, int.max(1, limite))
}

@external(erlang, "erlang", "phash2")
fn phash2(term: String, range: Int) -> Int

// ============================================================================
// What happens
// ============================================================================

/// The agent spoke on its own.
pub fn falou(estado: Estado, now_ms: Int) -> Estado {
  Estado(
    ..estado,
    tentativas: estado.tentativas + 1,
    aguardando: True,
    ultima_at: now_ms,
    penalizada: False,
  )
}

/// The slot opened and the agent chose not to speak: it is used anyway.
pub fn calou(estado: Estado) -> Estado {
  Estado(..estado, tentativas: estado.tentativas + 1)
}

/// The person wrote. An answer to a proactive message counts; three in a
/// row raise the ceiling (D3).
pub fn pessoa_falou(estado: Estado) -> Estado {
  case estado.aguardando {
    False -> estado
    True -> {
      let respondidas = estado.respondidas + 1
      let teto = case respondidas % respostas_para_subir == 0 {
        True -> int.min(teto_maximo, estado.teto + 1)
        False -> estado.teto
      }
      Estado(
        ..estado,
        aguardando: False,
        respondidas: respondidas,
        teto: teto,
        penalizada: False,
      )
    }
  }
}

/// A proactive message unanswered for a day lowers the ceiling, once (D3).
pub fn ver_ignorada(estado: Estado, now_ms: Int) -> Estado {
  case
    estado.aguardando
    && !estado.penalizada
    && now_ms - estado.ultima_at >= ignorada_apos_ms
  {
    False -> estado
    True ->
      Estado(
        ..estado,
        teto: int.max(teto_minimo, estado.teto - 1),
        respondidas: 0,
        penalizada: True,
      )
  }
}

// ============================================================================
// What the person sets (D2, D3, D5)
// ============================================================================

pub fn ligar(estado: Estado) -> Estado {
  Estado(..estado, ligada: True)
}

pub fn desligar(estado: Estado) -> Estado {
  Estado(..estado, ligada: False)
}

pub fn mais(estado: Estado) -> Estado {
  Estado(..estado, teto: int.min(teto_maximo, estado.teto + 1))
}

pub fn menos(estado: Estado) -> Estado {
  Estado(..estado, teto: int.max(teto_minimo, estado.teto - 1))
}

pub fn silencio(estado: Estado, de: Int, ate: Int) -> Result(Estado, String) {
  case de >= 0 && de < 24 && ate >= 0 && ate < 24 {
    True -> Ok(Estado(..estado, silencio_de: de, silencio_ate: ate))
    False -> Error("as horas do silêncio vão de 0 a 23")
  }
}

pub fn com_assuntos(estado: Estado, assuntos: Assuntos) -> Estado {
  Estado(..estado, assuntos: assuntos)
}

pub fn assuntos_de(texto: String) -> Result(Assuntos, Nil) {
  case string.lowercase(string.trim(texto)) {
    "leve" -> Ok(Leve)
    "livres" | "livre" -> Ok(Livres)
    "so_meus" | "só os meus" | "so os meus" | "meus" -> Ok(SoMeus)
    _ -> Error(Nil)
  }
}

pub fn assuntos_texto(assuntos: Assuntos) -> String {
  case assuntos {
    Leve -> "leve"
    Livres -> "livres"
    SoMeus -> "so_meus"
  }
}

/// The rule the agent follows, in its words.
pub fn regra_dos_assuntos(assuntos: Assuntos) -> String {
  case assuntos {
    Leve ->
      "Assuntos sensíveis (saúde, luto, dinheiro, relações): pode perguntar de leve como a pessoa está, mas não volte ao detalhe por conta própria."
    Livres ->
      "A pessoa liberou: você pode voltar a qualquer assunto que ela trouxe, com cuidado."
    SoMeus ->
      "Nunca toque por conta própria em assuntos sensíveis (saúde, luto, dinheiro, relações), nem de leve."
  }
}

/// A short account for the person.
pub fn resumo(estado: Estado) -> String {
  case estado.ligada {
    False -> "Puxar assunto por conta própria está desligado."
    True ->
      "Puxo assunto até "
      <> int.to_string(estado.teto)
      <> " vezes por dia, nunca entre "
      <> int.to_string(estado.silencio_de)
      <> "h e "
      <> int.to_string(estado.silencio_ate)
      <> "h, e nunca duas vezes seguidas sem você responder. Assuntos sensíveis: "
      <> case estado.assuntos {
        Leve -> "só pergunto de leve como você está."
        Livres -> "liberados."
        SoMeus -> "só se você puxar."
      }
  }
}

// ============================================================================
// Disk
// ============================================================================

pub fn path(data_dir: String, principal: String) -> String {
  agent_identity.self_dir(data_dir, principal) <> "/proativa.json"
}

pub fn carregar(data_dir: String, principal: String) -> Estado {
  case read_file(path(data_dir, principal)) {
    Error(_) -> inicial()
    Ok(text) -> json.parse(text, decoder()) |> result.unwrap(inicial())
  }
}

pub fn salvar(
  data_dir: String,
  principal: String,
  estado: Estado,
) -> Result(Nil, String) {
  let _ = ensure_dir(agent_identity.self_dir(data_dir, principal))
  write_file_atomic(path(data_dir, principal), json.to_string(encode(estado)))
}

/// Read, change and save under the person's lock: the clock and the
/// person's lane may both change it.
pub fn mudar(
  data_dir: String,
  principal: String,
  change: fn(Estado) -> Result(Estado, String),
) -> Result(Estado, String) {
  with_lock("proativa:" <> principal, fn() {
    use novo <- result.try(change(carregar(data_dir, principal)))
    use _ <- result.try(salvar(data_dir, principal, novo))
    Ok(novo)
  })
}

fn encode(estado: Estado) -> json.Json {
  json.object([
    #("ligada", json.bool(estado.ligada)),
    #("teto", json.int(estado.teto)),
    #("silencio_de", json.int(estado.silencio_de)),
    #("silencio_ate", json.int(estado.silencio_ate)),
    #("assuntos", json.string(assuntos_texto(estado.assuntos))),
    #("dia", json.string(estado.dia)),
    #("tentativas", json.int(estado.tentativas)),
    #("aguardando", json.bool(estado.aguardando)),
    #("ultima_at", json.int(estado.ultima_at)),
    #("respondidas", json.int(estado.respondidas)),
    #("penalizada", json.bool(estado.penalizada)),
  ])
}

fn decoder() -> decode.Decoder(Estado) {
  let d = inicial()
  use ligada <- decode.optional_field("ligada", d.ligada, decode.bool)
  use teto <- decode.optional_field("teto", d.teto, decode.int)
  use de <- decode.optional_field("silencio_de", d.silencio_de, decode.int)
  use ate <- decode.optional_field("silencio_ate", d.silencio_ate, decode.int)
  use assuntos <- decode.optional_field("assuntos", "leve", decode.string)
  use dia <- decode.optional_field("dia", "", decode.string)
  use tentativas <- decode.optional_field("tentativas", 0, decode.int)
  use aguardando <- decode.optional_field("aguardando", False, decode.bool)
  use ultima_at <- decode.optional_field("ultima_at", 0, decode.int)
  use respondidas <- decode.optional_field("respondidas", 0, decode.int)
  use penalizada <- decode.optional_field("penalizada", False, decode.bool)
  decode.success(Estado(
    ligada: ligada,
    teto: int.clamp(teto, teto_minimo, teto_maximo),
    silencio_de: de,
    silencio_ate: ate,
    assuntos: assuntos_de(assuntos) |> result.unwrap(Leve),
    dia: dia,
    tentativas: tentativas,
    aguardando: aguardando,
    ultima_at: ultima_at,
    respondidas: respondidas,
    penalizada: penalizada,
  ))
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file_atomic")
fn write_file_atomic(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "supernova_self_ffi", "with_lock")
fn with_lock(key: String, body: fn() -> a) -> a
