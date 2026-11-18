//// Check Config — CLI entry point.
////
//// Prints every configuration issue and exits with code 1 when any Error is
//// present. Usage: gleam run -m supernova/check_config_main -- [path]

import gleam/io
import supernova/config
import supernova/config_check

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "supernova_cli_ffi", "get_args")
fn get_args() -> List(String)

pub fn main() -> Nil {
  let path = case get_args() {
    [path, ..] -> path
    [] -> "supernova.yaml"
  }

  case config.load_from_file(path) {
    Error(error) -> {
      io.println("ERROR: " <> config.error_to_string(error))
      halt(1)
    }
    Ok(cfg) -> {
      let issues = config_check.check(cfg)
      let text = config_check.format_issues(issues)
      case text {
        "" -> io.println("OK: configuration is valid")
        _ -> io.println(text)
      }
      halt(config_check.exit_code(issues))
    }
  }
}
