import exception

@external(erlang, "test_env_ffi", "get_env")
pub fn get_env(key: String) -> Result(String, Nil)

@external(erlang, "test_env_ffi", "set_env")
pub fn set_env(key: String, value: String) -> Nil

@external(erlang, "test_env_ffi", "unset_env")
pub fn unset_env(key: String) -> Nil

/// Temporarily set an environment variable for the duration of `body`
/// and restore its prior state afterwards.
pub fn with_env(key: String, value: String, body: fn() -> a) -> a {
  let previous = get_env(key)
  set_env(key, value)
  use <- exception.defer(fn() {
    case previous {
      Ok(old) -> set_env(key, old)
      Error(_) -> unset_env(key)
    }
  })
  body()
}

/// Temporarily unset an environment variable for the duration of `body`
/// and restore its prior state afterwards.
pub fn without_env(key: String, body: fn() -> a) -> a {
  let previous = get_env(key)
  unset_env(key)
  use <- exception.defer(fn() {
    case previous {
      Ok(old) -> set_env(key, old)
      Error(_) -> unset_env(key)
    }
  })
  body()
}
