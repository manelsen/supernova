import exception

@external(erlang, "test_workspace_ffi", "create_temp_dir")
pub fn create_temp_dir(prefix: String) -> String

@external(erlang, "test_workspace_ffi", "get_workspace_root")
pub fn get_workspace_root() -> Result(String, Nil)

@external(erlang, "test_workspace_ffi", "set_workspace_root")
pub fn set_workspace_root(path: String) -> Nil

@external(erlang, "test_workspace_ffi", "reset_workspace_root")
pub fn reset_workspace_root() -> Nil

@external(erlang, "test_workspace_ffi", "remove_dir_recursive")
pub fn remove_dir_recursive(path: String) -> Nil

/// Run a test function with an isolated temporary workspace root.
/// Sets `SUPERNOVA_WORKSPACE_ROOT` to a unique `/tmp/supernova-test-...` path
/// and restores the previous environment and removes the temp dir afterwards.
pub fn with_isolated_workspace(prefix: String, body: fn(String) -> a) -> a {
  let previous = get_workspace_root()
  let root = create_temp_dir(prefix)
  set_workspace_root(root)
  use <- exception.defer(fn() {
    case previous {
      Ok(old) -> set_workspace_root(old)
      Error(_) -> reset_workspace_root()
    }
    remove_dir_recursive(root)
  })
  body(root)
}
