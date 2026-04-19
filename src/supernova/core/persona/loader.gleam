import gleam/result
import gleam/string
import supernova/core/persona/types.{type LoadError, type PersonaFiles}

/// Returns the `.supernova` directory for a workspace.
pub fn persona_dir(workspace_path: String) -> String {
  workspace_path <> "/.supernova"
}

/// Load all persona files from workspace.
///
/// Returns `BootstrapRequired` when any required file is missing.
pub fn load(workspace_path: String) -> Result(PersonaFiles, LoadError) {
  let base = persona_dir(workspace_path)
  use identity <- result.try(read_required(base <> "/IDENTITY.md"))
  use soul <- result.try(read_required(base <> "/SOUL.md"))
  use user <- result.try(read_required(base <> "/USER.md"))
  use style <- result.try(read_required(base <> "/STYLE.md"))
  Ok(types.PersonaFiles(
    identity: identity,
    soul: soul,
    user: user,
    style: style,
  ))
}

/// Write bootstrap persona files using the PRD templates and return loaded values.
pub fn write_bootstrap_files(
  workspace_path: String,
  name name: String,
  soul soul: String,
  style style: String,
  user user: String,
  timestamp timestamp: String,
) -> Result(PersonaFiles, LoadError) {
  let base = persona_dir(workspace_path)
  use _ <- result.try(ensure_persona_dir(base))

  let safe_name = default_if_empty(name, "Nova")
  let safe_soul = default_if_empty(soul, "Técnica, honesta e colaborativa.")
  let safe_style =
    default_if_empty(style, "Respostas curtas em português brasileiro.")
  let safe_user = default_if_empty(user, "Ainda sem preferências explícitas.")

  use _ <- result.try(write_file(
    base <> "/IDENTITY.md",
    identity_template(safe_name, timestamp),
  ))
  use _ <- result.try(write_file(base <> "/SOUL.md", soul_template(safe_soul)))
  use _ <- result.try(write_file(
    base <> "/STYLE.md",
    style_template(safe_style),
  ))
  use _ <- result.try(write_file(base <> "/USER.md", user_template(safe_user)))

  load(workspace_path)
}

/// Extract the configured agent name from IDENTITY.md content.
pub fn extract_name(identity: String) -> String {
  let marker = "**Nome:**"
  let lines = string.split(identity, "\n")
  extract_name_from_lines(lines, marker)
}

fn extract_name_from_lines(lines: List(String), marker: String) -> String {
  case lines {
    [] -> "Nova"
    [line, ..rest] ->
      case string.contains(line, marker) {
        True ->
          line
          |> string.replace(marker, "")
          |> string.trim
          |> default_if_empty("Nova")
        False -> extract_name_from_lines(rest, marker)
      }
  }
}

fn read_required(path: String) -> Result(String, LoadError) {
  case ffi_read_file(path) {
    Ok(content) -> Ok(content)
    Error(reason) ->
      case is_missing(reason) {
        True -> Error(types.BootstrapRequired)
        False -> Error(types.ReadFailed(path: path, reason: reason))
      }
  }
}

fn write_file(path: String, content: String) -> Result(Nil, LoadError) {
  case ffi_write_file(path, content) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(types.WriteFailed(path: path, reason: reason))
  }
}

fn ensure_persona_dir(path: String) -> Result(Nil, LoadError) {
  case ffi_ensure_dir(path) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(types.EnsureDirFailed(path: path, reason: reason))
  }
}

fn default_if_empty(value: String, fallback: String) -> String {
  case string.trim(value) {
    "" -> fallback
    trimmed -> trimmed
  }
}

fn is_missing(reason: String) -> Bool {
  let normalized = string.lowercase(reason)
  string.contains(normalized, "no such file")
  || string.contains(normalized, "enoent")
  || string.contains(normalized, "not found")
}

fn identity_template(name: String, timestamp: String) -> String {
  "# Identidade\n\n"
  <> "**Nome:** "
  <> name
  <> "\n\n"
  <> "**Papel:** Agente de IA do Supernova\n\n"
  <> "**Instanciado em:** "
  <> timestamp
  <> "\n"
}

fn soul_template(content: String) -> String {
  "# Alma e Valores\n\n"
  <> content
  <> "\n\n"
  <> "## Princípios não-negociáveis:\n"
  <> "- Ser honesto mesmo quando for difícil\n"
  <> "- Não fingir certeza quando não tem\n"
}

fn user_template(content: String) -> String {
  "# Perfil do Usuário\n\n"
  <> content
  <> "\n\n"
  <> "## Histórico Relacional:\n"
  <> "_Ainda sem histórico registrado._\n"
}

fn style_template(content: String) -> String {
  "# Estilo de Comunicação\n\n"
  <> content
  <> "\n\n"
  <> "## Padrões:\n"
  <> "- Idioma primário: português brasileiro\n"
  <> "- Evitar linguagem de bot (\"Claro!\", \"Com prazer!\", \"Certamente!\")\n"
}

@external(erlang, "supernova_file_system_ffi", "read_file")
fn ffi_read_file(path: String) -> Result(String, String)

@external(erlang, "supernova_file_system_ffi", "write_file")
fn ffi_write_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "supernova_file_system_ffi", "ensure_dir")
fn ffi_ensure_dir(path: String) -> Result(Nil, String)
