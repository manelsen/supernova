//// Link codes — how a person brings a new channel to their agent (PRD-I,
//// I-02, D3).
////
//// `/vincular` in a private chat of someone who has access gives a code;
//// `/vincular CÓDIGO` in a private chat of the new channel redeems it. A
//// code has six characters without 0/O or 1/I, lasts ten minutes and is
//// used once; an identity gets five wrong tries an hour. Codes are never
//// logged.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Command {
  /// `/vincular`: make a code.
  Issue
  /// `/vincular CÓDIGO`: link this identity with it.
  Redeem(code: String)
  /// `/desvincular` or `/desvincular <identity>`.
  Unlink(target: Option(String))
}

pub type RedeemError {
  InvalidCode
  TooManyTries
}

pub const code_ttl_ms = 600_000

const tries_window_ms = 3_600_000

const max_wrong_tries = 5

pub fn parse(content: String) -> Option(Command) {
  case
    string.split(string.trim(content), " ") |> list.filter(fn(w) { w != "" })
  {
    ["/vincular"] -> Some(Issue)
    ["/vincular", code] -> Some(Redeem(string.uppercase(code)))
    ["/desvincular"] -> Some(Unlink(None))
    ["/desvincular", target] -> Some(Unlink(Some(target)))
    _ -> None
  }
}

type Stored {
  Code(canonical: String, expires_at: Int)
  Owner(code: String)
  Failures(at: List(Int))
}

@external(erlang, "supernova_link_codes_ffi", "put")
fn put(key: String, value: Stored) -> Nil

@external(erlang, "supernova_link_codes_ffi", "get")
fn get(key: String) -> Result(Stored, Nil)

@external(erlang, "supernova_link_codes_ffi", "delete")
fn delete(key: String) -> Nil

@external(erlang, "supernova_link_codes_ffi", "random_code")
fn random_code() -> String

/// A fresh code for `canonical`; the previous one stops working.
pub fn issue(canonical: String, now: Int) -> String {
  case get("owner:" <> canonical) {
    Ok(Owner(old)) -> delete("code:" <> old)
    _ -> Nil
  }
  let code = random_code()
  put("code:" <> code, Code(canonical, now + code_ttl_ms))
  put("owner:" <> canonical, Owner(code))
  code
}

/// The person a code belongs to, if `claimant` may still try and the code
/// is valid. A valid code is spent.
pub fn redeem(
  claimant: String,
  code: String,
  now: Int,
) -> Result(String, RedeemError) {
  let recent = recent_failures(claimant, now)
  case list.length(recent) >= max_wrong_tries {
    True -> Error(TooManyTries)
    False ->
      case get("code:" <> string.uppercase(code)) {
        Ok(Code(canonical, expires_at)) if expires_at >= now -> {
          delete("code:" <> string.uppercase(code))
          delete("owner:" <> canonical)
          Ok(canonical)
        }
        _ -> {
          put("fail:" <> claimant, Failures([now, ..recent]))
          Error(InvalidCode)
        }
      }
  }
}

fn recent_failures(claimant: String, now: Int) -> List(Int) {
  case get("fail:" <> claimant) {
    Ok(Failures(at)) -> list.filter(at, fn(t) { t > now - tries_window_ms })
    _ -> []
  }
}
