-module(test_git_repo_ffi).
-export([with_temp_repo/1]).

%% Run Fun with the emulator cwd set to a freshly initialised git repository
%% under /tmp, restoring the original cwd afterwards even when Fun raises.
%%
%% The repository is created outside the project tree so tests never run git
%% against the supernova checkout.
with_temp_repo(Fun) ->
  {ok, OriginalCwd} = file:get_cwd(),
  make_code_paths_absolute(OriginalCwd),
  Unique = integer_to_list(erlang:unique_integer([positive, monotonic])),
  Dir = "/tmp/supernova-git-test-" ++ os:getpid() ++ "-" ++ Unique,
  try
    ok = filelib:ensure_dir(filename:join(Dir, ".keep")),
    ok = file:set_cwd(Dir),
    ok = init_repo(),
    Fun()
  catch
    Class:Reason:Stack ->
      {error,
       iolist_to_binary(
         io_lib:format("~p:~p~n~p", [Class, Reason, Stack])
       )}
  after
    _ = file:set_cwd(OriginalCwd),
    remove_recursive(Dir)
  end.

init_repo() ->
  run("git init -q ."),
  run("git config user.email test@example.com"),
  run("git config user.name 'Supernova Test'"),
  run("printf 'seed\\n' > seed.txt"),
  run("git add seed.txt"),
  run("git commit -q -m seed"),
  case filelib:is_dir(".git") of
    true -> ok;
    false -> error(git_init_failed)
  end.

%% Erlang resolves lazily loaded modules through the code path at call time.
%% When the test runner passed relative `-pa` entries, changing the cwd would
%% break loading of modules first touched inside the temp repo, so pin them to
%% the original working directory.
make_code_paths_absolute(Cwd) ->
  lists:foreach(
    fun(Dir) ->
      case filename:pathtype(Dir) of
        relative ->
          Absolute = filename:absname(Dir, Cwd),
          case filelib:is_dir(Absolute) of
            true -> _ = code:add_patha(Absolute);
            false -> ok
          end;
        _ ->
          ok
      end
    end,
    code:get_path()
  ),
  ok.

run(Command) ->
  _ = os:cmd(Command ++ " 2>&1"),
  ok.

remove_recursive(Path) ->
  case lists:prefix("/tmp/supernova-git-test-", Path) of
    true -> delete_recursive(Path);
    false -> ok
  end,
  ok.

delete_recursive(Path) ->
  case filelib:is_dir(Path) of
    true ->
      case file:list_dir(Path) of
        {ok, Entries} ->
          lists:foreach(
            fun(Entry) ->
              delete_recursive(filename:join(Path, Entry))
            end,
            Entries
          ),
          _ = file:del_dir(Path),
          ok;
        {error, _} ->
          ok
      end;
    false ->
      _ = file:delete(Path),
      ok
  end.
