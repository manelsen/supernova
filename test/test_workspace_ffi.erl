-module(test_workspace_ffi).
-export([create_temp_dir/1, get_workspace_root/0, set_workspace_root/1, reset_workspace_root/0, remove_dir_recursive/1]).

create_temp_dir(Prefix) ->
  Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
  PidStr = os:getpid(),
  PrefixList = binary_to_list(Prefix),
  Path = "/tmp/supernova-test-" ++ PrefixList ++ "-" ++ PidStr ++ "-" ++ Unique,
  ok = filelib:ensure_dir(Path ++ "/.keep"),
  list_to_binary(Path).

get_workspace_root() ->
  case os:getenv("SUPERNOVA_WORKSPACE_ROOT") of
    false -> {error, nil};
    Val -> {ok, list_to_binary(Val)}
  end.

set_workspace_root(Path) ->
  true = os:putenv("SUPERNOVA_WORKSPACE_ROOT", binary_to_list(Path)),
  nil.

reset_workspace_root() ->
  os:unsetenv("SUPERNOVA_WORKSPACE_ROOT"),
  nil.

remove_dir_recursive(PathBin) ->
  Path = binary_to_list(PathBin),
  case lists:prefix("/tmp/supernova-test-", Path) of
    true -> delete_recursive(Path);
    false -> ok
  end,
  nil.

delete_recursive(Path) ->
  case filelib:is_dir(Path) of
    true ->
      case file:list_dir(Path) of
        {ok, Entries} ->
          lists:foreach(fun(Entry) ->
            delete_recursive(filename:join(Path, Entry))
          end, Entries),
          _ = file:del_dir(Path),
          ok;
        {error, _} ->
          ok
      end;
    false ->
      _ = file:delete(Path),
      ok
  end.
