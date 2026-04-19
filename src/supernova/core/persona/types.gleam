import gleam/option.{type Option}

/// Persona files loaded from workspace disk.
pub type PersonaFiles {
  PersonaFiles(identity: String, soul: String, user: String, style: String)
}

/// Errors that may happen while loading or writing persona files.
pub type LoadError {
  BootstrapRequired
  ReadFailed(path: String, reason: String)
  WriteFailed(path: String, reason: String)
  EnsureDirFailed(path: String, reason: String)
}

/// Bootstrap finite state machine for identity onboarding.
pub type BootstrapState {
  AskingName
  AskingSoul
  AskingStyle
  AskingUser
  Complete
}

/// Optional user-provided answers collected during bootstrap.
pub type BootstrapDraft {
  BootstrapDraft(
    name: Option(String),
    soul: Option(String),
    style: Option(String),
  )
}
